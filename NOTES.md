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
