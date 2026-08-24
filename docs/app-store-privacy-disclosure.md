# Filuma — App Store privacy disclosure

Prepared for iOS 1.3.0 (build 6) on 2026-08-23. This is the conservative answer
set for the binary currently uploaded to App Store Connect.

## Recommended App Store Connect answers

1. **Do you or your third-party partners collect data from this app?** Yes.
2. Select **User Content → Other User Content**.
3. **Is this data linked to the user's identity?** Yes. Exported work blocks
   are written into the Google account the user connected.
4. **Is this data used for tracking?** No.
5. **Purposes:** App Functionality only.

Do not select advertising, marketing, analytics, product personalization, or
other purposes. Do not select contact information merely because Settings
shows the Google account email: that value is received from Google and retained
only on the device. Do not select audio data: Filuma does not store or transmit
the user's recording; Apple's speech service performs the optional
transcription under Apple's own data practices.

## Why “Data Not Collected” is not the safest answer

Filuma itself has no server, analytics, ads, or tracking. Most data is local.
Apple nevertheless defines collection to include data transmitted off-device
and retained by a third-party partner beyond what is necessary for a real-time
request. When a user enables **Export blocks to Google Calendar**, Filuma writes
task-derived block titles and times to that user's Google account, where Google
retains them. Export can continue after the initial toggle, so it does not meet
Apple's exception for an infrequent submission affirmatively chosen each time.

This disclosure is intentionally conservative. It describes only the ongoing
Google export path; Google import brings calendar data onto the device, Apple
Calendar uses Apple's on-device framework, and Filuma's local task store is not
off-device collection by the developer.

## Sources and code evidence

- Apple, “App privacy details on the App Store”:
  https://developer.apple.com/app-store/app-privacy-details/
- Apple, “Manage app privacy”:
  https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/
- `Filuma/GoogleCalendarService.swift`: Google export writes each active
  scheduled block's task title, start, and end to the connected primary
  calendar when `exportToGoogleCalendar` is enabled.
- `Filuma/SettingsView.swift`: Google export is separately opt-in and clearly
  labeled; the footer states that export mirrors work blocks to the user's
  primary Google calendar.
- `Filuma/PrivacyInfo.xcprivacy`: no tracking and no declared collected-data
  API category in the compiled app manifest. The App Store product-page answer
  is broader because it also covers direct third-party service behavior.
