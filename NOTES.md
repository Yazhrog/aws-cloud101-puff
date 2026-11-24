# Notes du groupe

Groupe : g11 · Membres : thomas.polverelli (solo) · App : https://github.com/traefik/whoami

Chaque décision est notée ici avec une ligne de justification. Ça devient le pitch de la soutenance.

## M0, setup + IAM
- Sortie du check :
  ```
  PASS M0 Floci reachable
  PASS M0 one IAM user per member (found 4)
  PASS M0 read-only auditor user exists
  PASS M0 auditor denied proof saved in NOTES.md
  PASS M0 group bucket exists
  ```
- Preuve AccessDenied (l'auditeur `g11-auditor` peut lire avec `ec2 describe-vpcs`, puis tente `s3api create-bucket --bucket g11-hacker`) :
  ```
  aws: [ERROR]: An error occurred (AccessDenied) when calling the CreateBucket operation: User is not authorized to perform: s3:CreateBucket
  ```
- Les droits admin sont donnés au groupe `g11-admins`, pas à chaque utilisateur : on gère les droits une seule fois, et ajouter un membre se fait en un `add-user-to-group`.
- L'auditeur n'a un Allow explicite que sur les actions de lecture : tout ce qui n'est pas autorisé est refusé par défaut.

## M1, compute + data
- Sortie du check :
  ```
  PASS M1 app image in ECR
  PASS M1 ECS service running (1 task)
  PASS M1 ALB answers 200
  PASS M1 RDS Postgres available
  PASS M1 S3 status page online
  PASS M1 infra/deploy script committed
  ```
- App : `traefik/whoami` (affiche son Hostname, utile pour voir le load balancing), image `localhost:5100/g11-app:v1`, port 80, sur ECS Fargate derrière l'ALB `g11-alb`.
- Base : RDS Postgres `g11-db` (db.t3.micro, 20 Go). Page de statut : site statique S3 `g11-site`.
- Mode VM testé une fois (EC2 + user data qui sert :8080, vu via `docker exec`), puis terminé : ce n'est pas notre plateforme.

### Ce qui ne va pas dans ce déploiement (volontairement naïf)
| Problème | Ce qui peut arriver | Pièce AWS qui corrige |
|---|---|---|
| SG de l'app ouvert à 0.0.0.0/0 sur le port 80 | n'importe qui contourne l'ALB et attaque le conteneur directement | chaîne de SG : l'app n'accepte que le SG de l'ALB (M2) |
| Tout dans le VPC par défaut avec IP publiques | chaque tâche est exposée sur internet, pas de séparation public/privé | VPC dédié, subnets privés + NAT, `assignPublicIp=DISABLED` (M2) |
| Base de données `--publicly-accessible` | scan + bruteforce du Postgres depuis internet, fuite de données | subnets privés + SG base qui n'accepte que le SG de l'app (M2) |
| Mot de passe `ChangeMe-123` en clair (historique shell, script commité) | quiconque lit le repo a la base | Secrets Manager + rôle d'exécution ECS (M3) |
| Tout le monde avec des clés admin | une clé qui fuit = tout le compte perdu | rôles à privilège minimal (deployer), STS (M3) |
| Pas de logs ni d'alarmes | une panne ou une attaque passe inaperçue | CloudWatch Logs + alarme -> SNS -> pager (M3) |
| Un seul conteneur à un seul endroit | il meurt ou l'AZ tombe = site down | 2+ tâches sur 2 AZ + autoscaling (M4) |
| Pas de CDN ni de HTTPS | trafic en clair, page de statut servie depuis un seul point | CloudFront (+ ACM pour HTTPS) (M4) |
| Tout tapé à la main | impossible à reconstruire à l'identique, dérive | CloudFormation, rebuild en une commande (M5) |

## M2, réseau privé
- Sortie du check :
  ```
  PASS M2 VPC g11-vpc exists
  PASS M2 2 public subnets (route to IGW)
  PASS M2 2 private subnets (route to NAT)
  PASS M2 ALB in the public subnets
  PASS M2 ALB answers 200
  PASS M2 app service in the private subnets
  PASS M2 app tasks without public IP
  PASS M2 app security group not open to 0.0.0.0/0
  PASS M2 database in the VPC, not public
  PASS M2 database only reachable from the app's group
  PASS M2 intruder blocked from the app
  PASS M2 naive deploy deleted (no public DB, no service outside the VPC)
  ```
- Intruder (`./checks/intruder.sh`) :
  ```
  intruder -> app 172.17.0.8:80        : BLOCKED
  intruder -> db  172.17.0.2:7002 : REACHED
  ```
  Le `REACHED` côté base est une limite de Floci (son proxy RDS ignore les security groups). La règle est juste : le SG `g11-db-sg2` n'accepte le 5432 que depuis le SG de l'app.
- VPC `g11-vpc` 10.0.0.0/16 : publics 10.0.1.0/24 (1a) et 10.0.2.0/24 (1b) pour l'ALB, privés 10.0.11.0/24 (1a) et 10.0.12.0/24 (1b) pour l'app et la base. Deux AZ pour que l'ALB survive à la perte d'une zone.
- Une seule porte publique : l'ALB `g11-alb2`. L'app n'a pas d'IP publique et sort par le NAT, la base n'est pas publique.
- Chaîne de SG : internet -> ALB:80 -> app:80 -> base:5432. Chaque couche n'accepte que la couche d'avant. Sur Floci l'app autorise 172.17.0.0/16 (le bridge Docker où vit l'ALB) ; sur AWS ce serait `--source-group` du SG de l'ALB.
- Exercice de panne :
  - Panne B (retirer la règle 172.17.0.0/16 + force-new-deployment) : le site est resté à 200, car l'ancienne tâche reste en place tant que la nouvelle n'est pas saine, et les connexions établies continuent. On a remis la règle.
  - Panne C (desired-count 0) : l'ALB répond `503 No targets available`. Réparé avec desired-count 1, 200 au bout de 8 s.
- Le déploiement naïf de M1 est supprimé : service `g11-app`, `g11-alb`, `g11-tg`, la base publique `g11-db` et les SG ouverts du VPC par défaut.

### À réfléchir
- *L'app privée n'arrive pas à joindre la base* : vérifier dans l'ordre le SG de la base (5432 depuis le SG de l'app ?), le SG de l'app en sortie, que la base et l'app sont dans le même VPC, l'endpoint et le port utilisés, puis le NACL des subnets.
- *Sauter le NAT et donner une IP publique à l'app* : ça marche, mais chaque tâche devient joignable depuis internet dès qu'un SG est trop large. Le NAT ne laisse que les connexions sortantes.
- *VPC analytics + accès bureau* : peering ou Transit Gateway entre les VPC (CIDR qui ne se chevauchent pas), VPN site-à-site ou Direct Connect pour le bureau, et des SG qui n'ouvrent que les ports nécessaires.
- *Facture NAT doublée* : regarder qui sort par le NAT. Des VPC endpoints pour S3/DynamoDB/ECR évitent de payer le NAT pour du trafic AWS. Un NAT par AZ coûte plus mais évite le trafic inter-AZ et le point de panne unique.
- *Pourquoi l'ALB sur 2 AZ, et le point faible* : l'ALB exige 2 subnets dans 2 AZ pour survivre à la perte d'une zone. Le point faible reste l'unique conteneur : s'il meurt, plus rien derrière l'ALB (corrigé en M4 avec 2 tâches sur 2 AZ).

## M3, secrets + supervision + moindre privilège
- Sortie du check :
  ```
  PASS M3 secret g11/db-password exists
  PASS M3 the running task gets the password from Secrets Manager
  PASS M3 no password in clear in the task definition
  PASS M3 an execution role, not admin
  PASS M3 app logs land in CloudWatch (/ecs/g11-app)
  PASS M3 an alarm pages the g11-alerts topic
  PASS M3 the topic delivers to an SQS pager
  PASS M3 a paged alarm saved in NOTES.md
  PASS M3 deployer role without wildcard actions
  PASS M3 deployer AccessDenied proof saved in NOTES.md
  PASS M3 no password left in your current scripts
  ```
- Mot de passe : secret Secrets Manager `g11/db-password` (24 caractères aléatoires). La base `g11-db2` a été tournée sur cette valeur avec `modify-db-instance --apply-immediately`, donc l'ancien mot de passe en clair ne marche plus. `infra/deploy.sh` ne contient plus aucun mot de passe : il crée le secret puis le relit.
- La tâche (révision 2 de `g11-app`) reçoit `DB_HOST` et `DB_PORT` en clair (de la config, pas des secrets) et `DB_PASSWORD` via `secrets.valueFrom` = ARN du secret. `describe-task-definition` ne montre que l'ARN.
- Rôle d'exécution `g11-exec-role` : approuvé seulement par `ecs-tasks.amazonaws.com`, il peut lire ce seul secret et écrire des logs. Pas d'admin.
- Logs : groupe `/ecs/g11-app`, préfixe `app`. Premier log : `Starting up on port 80`.
- Pager : alarme `g11-errors` (somme de `g11/Errors` >= 1 sur 60 s) -> SNS `g11-alerts` -> SQS `g11-pager`. Test : `put-metric-data Errors=3`, page reçue dans la file :
  ```
  Subject: ALARM: "g11-errors"
  NewStateValue: ALARM (avant : INSUFFICIENT_DATA)
  NewStateReason: Threshold Crossed: 1 datapoint(s) breaching the threshold.
  StateChangeTime: 2026-11-24T19:19:04.000+0000
  ```

## deployer proof
- Le deployer ne peut pas supprimer la base : `AccessDenied` (rds:DeleteDBInstance), sortie complète ci-dessous.
- Rôle `g11-deployer`, politique `deploy-only` : `ecs:DescribeServices`/`UpdateService` sur le seul service `g11/g11-app2`, enregistrer des task definitions, lire les logs, et `iam:PassRole` sur le seul rôle d'exécution. Aucune action en `*`.
- `sts assume-role` -> `arn:aws:sts::000000000000:assumed-role/g11-deployer/thomas`. `update-service --desired-count 1` passe. Supprimer la base est refusé :
  ```
  $ aws rds delete-db-instance --db-instance-identifier g11-db2 --skip-final-snapshot
  aws: [ERROR]: An error occurred (AccessDenied) when calling the DeleteDBInstance operation: User is not authorized to perform: rds:DeleteDBInstance
  ```

### À réfléchir
- *Mot de passe passé en variable d'environnement* : quiconque peut lire la task definition (ou faire `docker inspect`) le voit, et il finit dans l'historique et dans git. Avec `secrets.valueFrom`, seuls le rôle d'exécution et les admins du secret le voient. Il reste visible dans l'environnement du conteneur en cours d'exécution, donc l'accès `ecs:ExecuteCommand` doit être limité aussi.
- *SCP qui refuse `s3:DeleteBucket` sur Prod* : une SCP borne ce que le compte peut faire, même pour un admin. Même la clé admin qui a fuité ne peut pas supprimer les buckets. Elle ne donne aucun droit, elle n'en retire que.
- *Conteneurs démarrés avec l'ancien mot de passe* : le secret est lu au démarrage de la tâche. Après une rotation, les tâches déjà lancées gardent l'ancienne valeur et échouent à la prochaine connexion. Il faut relancer (`--force-new-deployment`) ou utiliser une rotation à deux utilisateurs alternés.
- *Snapshots copiés dans un compte séparé* : le chiffrement protège contre la lecture, pas contre la suppression. Si le compte prod est compromis, l'attaquant peut supprimer la base et ses snapshots. Une copie dans un compte de sauvegarde (avec sa propre clé KMS) survit.
- *Alarme CPU à 3 h à cause du job de nuit* : c'est un faux positif qui apprend à ignorer le pager. Il faut alarmer sur ce qui touche les utilisateurs (erreurs 5xx, latence), ou exclure la fenêtre du job, ou demander plusieurs périodes d'évaluation.
