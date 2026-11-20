# Notes du groupe

Groupe : g11 · Membres : thomas.polverelli, X, X · App : <URL git de l'app déployée>

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
