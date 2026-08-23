# Semreh Privacy Policy

**Effective date:** August 16, 2026

Semreh is a native iPhone and iPad client for a Hermes agent that you host and configure. This policy describes the Semreh iOS app distributed by Jacob Moore from [`jmogainz/semreh-ios`](https://github.com/jmogainz/semreh-ios). It does not describe the independently operated upstream Hermex app.

## Summary

Semreh does not include advertising, third-party analytics, cross-app tracking, or a developer-operated data relay. The app communicates directly with the Hermes server URL that you configure. Jacob Moore and the Semreh project do not receive the content of those communications through the app.

## Data handled by the app

Depending on the features you choose to use, Semreh may handle:

- Server address and connection settings.
- Authentication credentials for your configured Hermes server.
- Chat messages, agent responses, session metadata, tasks, skills, workspace files, and other content returned by or sent to that server.
- Files and photos that you explicitly select or share into the app.
- Photos that you explicitly capture with the camera for attachment to a chat.
- Microphone audio and speech-recognition results when you explicitly use dictation or record a voice note.
- Local notification content when you enable response-completion notifications.

## How data is used and transmitted

Semreh uses this data only to provide the feature you requested. Files, photos, PDFs, camera captures, and other composer attachments are uploaded directly to the configured Hermes server immediately after you select, paste, capture, or import them. The corresponding chat message is not sent until you tap Send. Content imported through the share extension is staged locally until the containing app opens it; attachments then upload to the configured server before the chat message is sent. Network operators used to reach that server, such as your VPN or Tailscale configuration, may process traffic according to their own policies.

Dictation may use on-device speech recognition, Apple speech-recognition services, or a speech-to-text service exposed by your configured Hermes server, depending on the option you select and device capabilities. When you explicitly record a voice note, Semreh records audio to a temporary local file, sends the voice-note audio to your configured Hermes server for transcription, uploads it as an audio attachment after successful transcription, and sends the transcript and attachment as the message. The temporary local recording file is deleted after it is read or when recording is cancelled. Server-side audio, transcripts, messages, and attachments follow the retention policy of your configured Hermes server. Apple’s handling of dictation data is governed by Apple’s privacy policies.

Semreh does not sell personal information and does not use app data for advertising or tracking.

## Local storage and retention

Semreh stores connection credentials in the iOS Keychain. It may retain app preferences and cached server content on your device so the app can restore settings and show previously loaded information. Content stored by your Hermes server is retained according to that server’s configuration. Removing the app deletes its ordinary local app container; Keychain behavior is controlled by iOS.

You control server-side deletion and retention through your Hermes server. You can remove local Semreh data by deleting the app from your device.

## Device permissions

Semreh requests a permission only when a related feature needs it:

- **Camera:** capture a photo for a chat attachment.
- **Photos:** select chat attachments or save an exported workspace image.
- **Microphone:** dictate text in the composer or record a voice note you explicitly start.
- **Speech recognition:** turn explicit composer dictation into editable draft text.
- **Notifications:** notify you when an agent response completes.

You can change these permissions in iOS Settings.

## Security

You are responsible for selecting and securing the Hermes server, network path, and credentials you configure. Semreh uses the connection URL you provide and is intended for trusted HTTPS or private-network deployments.

## Children

Semreh is a general-purpose developer tool and is not directed to children under 13.

## Changes

Material changes to this policy will be published in this repository with an updated effective date.

## Contact and support

For privacy questions or support, open an issue at <https://github.com/jmogainz/semreh-ios/issues>.
