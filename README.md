# App Store Connect Automation (Dart)

Automates release notes and review submission after IPA upload to App Store Connect.

**Built by Filip Kowalski**  
X: [@filippkowalski](https://twitter.com/filippkowalski)  
Website: [fkowalski.com](https://fkowalski.com)  
Support: [buymeacoffee.com/filipkowalski](https://buymeacoffee.com/filipkowalski)

## Setup

### 1. Install Dependencies

```bash
dart pub get
```

### 2. Set Environment Variables

```bash
export APP_STORE_API_KEY_ID=your_key_id
export APP_STORE_ISSUER_ID=your_issuer_id
export APP_STORE_P8_KEY_PATH=/path/to/AuthKey.p8  # optional
```

You can find these values in **App Store Connect > Users and Access > Keys**.

Default P8 key path: `~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8`

## Usage

### Basic Usage

```bash
dart submit_to_app_store.dart 1.13.0
```

### With Build Number

```bash
dart submit_to_app_store.dart 1.13.0+30
```

### Custom Project Path

```bash
dart submit_to_app_store.dart 1.13.0 --project-path /path/to/project
```

### Dry Run (Preview Only)

```bash
dart submit_to_app_store.dart 1.13.0 --dry-run
```

### Override Bundle ID

```bash
dart submit_to_app_store.dart 1.13.0 --bundle-id com.example.app
```

## What It Does

1. **Detects Bundle ID** - Auto-detects from your Xcode project
2. **Finds Your App** - Locates the app in App Store Connect
3. **Waits for Build** - Waits for the uploaded build to finish processing
4. **Creates/Updates Version** - Gets existing or creates new version
5. **Links Build** - Associates the build with the version
6. **Adds Release Notes** - Adds notes to all localizations
7. **Submits for Review** - Submits the version for App Store review

## Release Notes

Default release notes: "Bug fixes and improvements."

To customize, edit the `releaseNotes` constant in `submit_to_app_store.dart`.

## Making It Executable

```bash
chmod +x submit_to_app_store.dart
./submit_to_app_store.dart 1.13.0
```

## Workflow Integration

Typical workflow:

1. Build and upload IPA:
   ```bash
   flutter build ipa
   xcrun altool --upload-app -f build/ios/ipa/*.ipa \
     --type ios \
     --apiKey $APP_STORE_API_KEY_ID \
     --apiIssuer $APP_STORE_ISSUER_ID
   ```

2. Run this script:
   ```bash
   dart submit_to_app_store.dart 1.13.0+30
   ```

## Key Differences from Python Version

- Uses `jose` package for JWT token generation (ES256 signing)
- Native Dart async/await instead of blocking calls
- Strong typing with Dart's type system
- Uses `args` package for command-line argument parsing
- Uses `http` package for HTTP requests

## Troubleshooting

### "Missing dependencies"
Run `dart pub get`

### "P8 key file not found"
Set `APP_STORE_P8_KEY_PATH` or place the key at: `~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8`

### "App not found"
Verify the bundle ID matches your app in App Store Connect

### "Build not found"
Make sure you uploaded the IPA first using `xcrun altool`

## License

This is a conversion of the original Python script to Dart, maintaining the same functionality and workflow.

