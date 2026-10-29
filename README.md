# Dictée

Une app de dictée vocale pour Mac, gratuite et 100 % locale, inspirée de Wispr Flow.
Maintiens une touche, parle, relâche : le texte s'écrit là où se trouve ton curseur, dans n'importe quelle app.

- **Gratuit** : aucun abonnement, aucune clé d'API.
- **Privé** : la transcription tourne sur ton Mac grâce à [Whisper](https://github.com/openai/whisper) via [WhisperKit](https://github.com/argmaxinc/WhisperKit). Ta voix n'est jamais envoyée sur internet.
- **Français soigné** : ponctuation, accents et typographie française (espace insécable avant ? ! ; :).

## Configuration requise

- Un Mac avec puce Apple (M1, M2, M3, M4…)
- macOS 14 Sonoma ou plus récent
- Environ 700 Mo d'espace libre pour le modèle de reconnaissance vocale

## Installation

1. Télécharge **`Dictee.zip`** depuis la page [Releases](../../releases/latest) et ouvre-le.
2. Glisse **`Dictee.app`** dans ton dossier **Applications**.
3. Lance Dictée. macOS va la bloquer, car elle n'est pas validée par Apple :
   - ouvre **Réglages Système → Confidentialité et sécurité** ;
   - tout en bas, clique sur **« Ouvrir quand même »** à côté de Dictée, puis confirme.
4. Autorise le **micro** quand macOS le demande.
5. Autorise l'**accessibilité**, qui permet d'écrire le texte dans l'app où tu te trouves :
   - **Réglages Système → Confidentialité et sécurité → Accessibilité** ;
   - active **Dictee**. Si elle n'apparaît pas, ajoute-la avec le bouton **+**.
6. Au premier lancement, le modèle Whisper (environ 630 Mo) se télécharge tout seul. L'icône 🎤 dans la barre de menu affiche « Prêt » quand c'est terminé.

## Utilisation

- Clique dans un champ texte, **maintiens ⌥ Option**, parle, puis relâche.
- Une bulle apparaît en bas de l'écran pendant que tu parles, puis le texte est collé.
- Dans le menu 🎤 :
  - **Raccourci** : choisis ta touche (Option, Commande droite, Contrôle, Fn…) ;
  - **Langue** : français, ou détection automatique pour dicter dans d'autres langues ;
  - **Lancer au démarrage**.

## Mises à jour

Dictée vérifie une fois par jour s'il existe une nouvelle version sur cette page GitHub. Seul le numéro de la dernière version est demandé : rien d'autre n'est envoyé.
Quand une mise à jour est disponible, le menu 🎤 affiche **« ⬆️ Mise à jour disponible »**. Clique dessus pour ouvrir la page de téléchargement, puis :

1. quitte Dictée (menu 🎤 → Quitter) ;
2. remplace l'ancienne `Dictee.app` dans Applications par celle du nouveau zip ;
3. relance-la. Si la dictée n'écrit plus rien, réactive Dictee dans **Accessibilité** (voir Dépannage).

> Si tu choisis la touche 🌐 Fn, règle **Réglages Système → Clavier → « Appuyer sur la touche 🌐 pour »** sur **Ne rien faire**.

## Dépannage

- **Rien ne s'écrit** : vérifie dans le menu 🎤 que la ligne affiche « ✅ Accessibilité autorisée ». Sinon, supprime Dictee de la liste Accessibilité avec le bouton **−**, rajoute-la avec **+**, puis relance l'app.
- **Journal** : `~/Library/Logs/Dictee.log` note chaque étape (lancement, enregistrement, collage).

## Compiler depuis le code

Il faut les outils de développement d'Apple (`xcode-select --install`).

```bash
./build.sh
```

Le script compile, signe et installe l'app dans `~/Applications`. Il utilise un certificat de signature nommé « Dictee Signature Perso » s'il existe dans ton trousseau, sinon une signature ad hoc. Dans ce second cas, il faudra réautoriser l'accessibilité après chaque compilation.
