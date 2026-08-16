# CDM Custom TTS

CDM Custom TTS is a World of Warcraft addon by **Mimezu** that extends the
native Cooldown Manager alert editor with short, custom text-to-speech phrases
and voice selection.

It stays inside Blizzard's existing alert workflow: select **Text to Speech** as
the sound alert, enter the phrase you want to hear, choose a voice, and apply the
alert normally.

## Features

- Custom spoken text for native Cooldown Manager spell alerts
- Installed system TTS voice selection
- In-editor voice preview
- Per-spell and per-alert-event phrases
- Combat-safe integration that does not replace Blizzard Cooldown Viewer code
- Lightweight, standalone addon with no dependencies

## Installation

1. Download or clone this repository.
2. Place the `CDMCustomTTS` folder in:
   `World of Warcraft/_retail_/Interface/AddOns/`
3. Restart World of Warcraft or type `/reload` if the addon was already present.

## Usage

1. Open Blizzard's Cooldown Manager settings.
2. Add or edit a spell alert.
3. Set the alert type to **Sound**.
4. Select **Text to Speech** under **Sound Alert**.
5. Enter your custom spoken text and choose a voice.
6. Use **Preview**, then select **Apply Changes**.

TTS volume is controlled by World of Warcraft's native text-to-speech settings.

## Compatibility

CDM Custom TTS targets current Retail World of Warcraft and Blizzard's native
Cooldown Manager. It is not intended for Classic clients.
