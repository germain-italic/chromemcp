# Feuille de route

## Support macOS avec Chrome dédié

**Statut : planifié, en attente d’un test sur macOS.** Aucune implémentation ne sera faite avant de pouvoir la valider sur un Mac.

Objectif : lancer une fenêtre Chrome visible, distincte du Chrome habituel et de son profil, puis la rendre contrôlable par Chrome DevTools MCP.

Travaux prévus :

- [ ] Définir l’emplacement persistant du profil dédié et les réglages macOS.
- [ ] Ajouter le lancement de Chrome en mode headed avec un profil de données séparé.
- [ ] Configurer la connexion MCP au port DevTools local de cette instance.
- [ ] Vérifier l’isolation du profil habituel, le lancement visible et le contrôle MCP sur un Mac.
- [ ] Documenter l’installation, la configuration et le retour au profil dédié après redémarrage.

Contraintes de conception :

- Ne jamais réutiliser le profil Chrome par défaut de macOS.
- Garder le port DevTools accessible uniquement en local.
- Confirmer le fonctionnement sur la version de Chrome ciblée, notamment les exigences de profil personnalisé pour le débogage distant.
- Décider après essai si le profil dédié doit être persistant ou temporaire.
