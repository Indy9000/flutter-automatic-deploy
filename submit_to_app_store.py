#!/usr/bin/env python3
"""
=============================================================================
Flutter Automatic Deploy - App Store Connect API Automation
=============================================================================

Built by Filip Kowalski
X: @filippkowalski
Website: fkowalski.com
Support: https://buymeacoffee.com/filipkowalski

Automates release notes and review submission after IPA upload.

=============================================================================

Usage:
    ./submit_to_app_store.py <version> [--project-path PATH] [--dry-run]

Example:
    ./submit_to_app_store.py 1.13.0
    ./submit_to_app_store.py 1.13.0 --project-path /path/to/project
    ./submit_to_app_store.py 1.13.0 --dry-run

Environment Variables (required):
    APP_STORE_API_KEY_ID     - App Store Connect API Key ID
    APP_STORE_ISSUER_ID      - App Store Connect Issuer ID
    APP_STORE_P8_KEY_PATH    - Path to .p8 private key file (default: ~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8)

Requirements:
    pip3 install PyJWT requests cryptography
"""

import os
import sys
import time
import json
import re
import argparse
from datetime import datetime, timedelta
from pathlib import Path

try:
    import jwt
    import requests
except ImportError:
    print("Missing dependencies. Install with:")
    print("   pip3 install PyJWT requests cryptography")
    sys.exit(1)

# API Configuration from environment variables
API_KEY_ID = os.environ.get("APP_STORE_API_KEY_ID")
ISSUER_ID = os.environ.get("APP_STORE_ISSUER_ID")
P8_KEY_PATH = os.environ.get(
    "APP_STORE_P8_KEY_PATH",
    os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{API_KEY_ID}.p8") if API_KEY_ID else None
)
BASE_URL = "https://api.appstoreconnect.apple.com/v1"
RELEASE_NOTES = "Bug fixes and improvements."


# Colors for output
class Colors:
    BLUE = '\033[0;34m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    RED = '\033[0;31m'
    CYAN = '\033[0;36m'
    NC = '\033[0m'  # No Color


def log(emoji, message, color=Colors.NC):
    """Print colored log message with emoji"""
    print(f"{color}{emoji} {message}{Colors.NC}")


def check_environment_variables():
    """Check that required environment variables are set"""
    missing = []

    if not API_KEY_ID:
        missing.append("APP_STORE_API_KEY_ID")
    if not ISSUER_ID:
        missing.append("APP_STORE_ISSUER_ID")

    if missing:
        log("", "Missing required environment variables:", Colors.RED)
        for var in missing:
            log("", f"  - {var}", Colors.RED)
        print()
        log("", "Set them with:", Colors.YELLOW)
        log("", "  export APP_STORE_API_KEY_ID=your_key_id", Colors.CYAN)
        log("", "  export APP_STORE_ISSUER_ID=your_issuer_id", Colors.CYAN)
        log("", "  export APP_STORE_P8_KEY_PATH=/path/to/AuthKey.p8  # optional", Colors.CYAN)
        print()
        log("", "You can find these in App Store Connect > Users and Access > Keys", Colors.YELLOW)
        sys.exit(1)


def find_bundle_id(project_path):
    """Auto-detect bundle ID from Xcode project"""
    log("", "Detecting bundle ID from Xcode project...", Colors.CYAN)

    # Look for project.pbxproj file
    ios_path = Path(project_path) / "ios"

    if not ios_path.exists():
        # Try mobile/ios for nested Flutter projects
        ios_path = Path(project_path).parent / "ios"

    pbxproj_files = list(ios_path.glob("**/project.pbxproj"))

    if not pbxproj_files:
        log("", "Could not find project.pbxproj file", Colors.RED)
        return None

    pbxproj_path = pbxproj_files[0]

    # Parse bundle ID from project file
    with open(pbxproj_path, 'r') as f:
        content = f.read()

        # Look for PRODUCT_BUNDLE_IDENTIFIER
        match = re.search(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);', content)

        if match:
            bundle_id = match.group(1).strip().strip('"')

            # Handle $(PRODUCT_BUNDLE_IDENTIFIER) references
            if bundle_id.startswith('$('):
                # Look for the actual value
                match = re.search(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?([a-z0-9\.]+)"?;', content)
                if match:
                    bundle_id = match.group(1)

            log("", f"Found bundle ID: {bundle_id}", Colors.GREEN)
            return bundle_id

    log("", "Could not parse bundle ID from project file", Colors.RED)
    return None


def generate_jwt_token():
    """Generate JWT token for App Store Connect API"""
    if not os.path.exists(P8_KEY_PATH):
        log("", f"P8 key file not found: {P8_KEY_PATH}", Colors.RED)
        log("", "Set APP_STORE_P8_KEY_PATH or place the key at the default location", Colors.YELLOW)
        sys.exit(1)

    # Token expires in 19 minutes (max is 20, use 19 to be safe)
    dt = datetime.now() + timedelta(minutes=19)

    headers = {
        "alg": "ES256",
        "kid": API_KEY_ID,
        "typ": "JWT"
    }

    payload = {
        "iss": ISSUER_ID,
        "iat": int(time.time()),
        "exp": int(time.mktime(dt.timetuple())),
        "aud": "appstoreconnect-v1"
    }

    try:
        with open(P8_KEY_PATH, "rb") as f:
            signing_key = f.read()

        token = jwt.encode(payload, signing_key, algorithm="ES256", headers=headers)
        return token
    except Exception as e:
        log("", f"Failed to generate JWT token: {e}", Colors.RED)
        sys.exit(1)


def make_api_request(method, endpoint, data=None, retries=3):
    """Make authenticated API request with retry logic"""
    token = generate_jwt_token()
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }

    url = f"{BASE_URL}{endpoint}"

    for attempt in range(retries):
        try:
            if method == "GET":
                response = requests.get(url, headers=headers, timeout=30)
            elif method == "POST":
                response = requests.post(url, headers=headers, json=data, timeout=30)
            elif method == "PATCH":
                response = requests.patch(url, headers=headers, json=data, timeout=30)

            # Handle rate limiting
            if response.status_code == 429:
                wait_time = int(response.headers.get('Retry-After', 60))
                log("", f"Rate limited. Waiting {wait_time}s...", Colors.YELLOW)
                time.sleep(wait_time)
                continue

            # Handle errors
            if response.status_code >= 400:
                error_data = response.json() if response.content else {}
                error_msg = error_data.get('errors', [{}])[0].get('detail', 'Unknown error')

                log("", f"API Error ({response.status_code}): {error_msg}", Colors.RED)

                if attempt < retries - 1:
                    log("", f"Retrying... (attempt {attempt + 2}/{retries})", Colors.YELLOW)
                    time.sleep(5 * (attempt + 1))  # Exponential backoff
                    continue

                return None

            return response.json()

        except requests.exceptions.Timeout:
            log("", "Request timed out", Colors.YELLOW)
            if attempt < retries - 1:
                time.sleep(5 * (attempt + 1))
                continue
            return None
        except requests.exceptions.RequestException as e:
            log("", f"Network error: {e}", Colors.RED)
            if attempt < retries - 1:
                time.sleep(5 * (attempt + 1))
                continue
            return None

    return None


def find_app_by_bundle_id(bundle_id):
    """Find app by bundle ID"""
    log("", f"Finding app with bundle ID: {bundle_id}", Colors.CYAN)

    response = make_api_request("GET", f"/apps?filter[bundleId]={bundle_id}")

    if not response or not response.get('data'):
        log("", f"App not found with bundle ID: {bundle_id}", Colors.RED)
        log("", "Make sure the app exists in App Store Connect", Colors.YELLOW)
        return None

    app_id = response['data'][0]['id']
    app_name = response['data'][0]['attributes']['name']
    log("", f"Found app: {app_name} (ID: {app_id[:12]}...)", Colors.GREEN)
    return app_id


def wait_for_build_processing(app_id, expected_build_number=None, max_wait_minutes=60, dry_run=False):
    """Wait for a specific build to finish processing"""
    if expected_build_number:
        log("", f"Waiting for build {expected_build_number} to finish processing (max {max_wait_minutes} min)...", Colors.CYAN)
    else:
        log("", f"Waiting for latest build to finish processing (max {max_wait_minutes} min)...", Colors.CYAN)

    if dry_run:
        log("", "[DRY RUN] Skipping build processing wait", Colors.YELLOW)
        return "dry-run-build-id"

    start_time = time.time()
    max_wait_seconds = max_wait_minutes * 60
    last_state = None
    last_version = None

    while True:
        # Get recent builds (limit 5 to catch the new build faster)
        response = make_api_request(
            "GET",
            f"/builds?filter[app]={app_id}&sort=-uploadedDate&limit=5"
        )

        if not response or not response.get('data'):
            log("", "No builds found", Colors.RED)
            log("", "Make sure you uploaded the IPA with xcrun altool first", Colors.YELLOW)
            return None

        # Look for the specific build or use the latest
        target_build = None

        if expected_build_number:
            # Search for the specific build number
            for build in response['data']:
                build_version = build['attributes'].get('version', '')
                if build_version == expected_build_number:
                    target_build = build
                    break

            if not target_build:
                # Build not found yet, keep waiting
                elapsed = time.time() - start_time
                if elapsed > max_wait_seconds:
                    log("", f"Timeout after {max_wait_minutes} minutes", Colors.YELLOW)
                    log("", f"Build {expected_build_number} never appeared in App Store Connect", Colors.YELLOW)
                    log("", "Check App Store Connect to verify the upload succeeded", Colors.YELLOW)
                    return None

                # Show waiting message every 30 seconds
                if int(elapsed) % 30 == 0 and elapsed > 0:
                    log("", f"Still waiting for build {expected_build_number} to appear... ({int(elapsed)}s elapsed)", Colors.BLUE)

                time.sleep(5)
                continue
        else:
            # No specific build number, use the latest
            target_build = response['data'][0]

        build_id = target_build['id']
        processing_state = target_build['attributes'].get('processingState', 'UNKNOWN')
        version = target_build['attributes'].get('version', 'unknown')

        # Show progress only if state changed
        if processing_state != last_state or version != last_version:
            log("", f"Build {version} - State: {processing_state}", Colors.BLUE)
            last_state = processing_state
            last_version = version

        if processing_state == "VALID":
            log("", f"Build {version} is ready!", Colors.GREEN)
            return build_id
        elif processing_state == "INVALID":
            log("", f"Build {version} processing failed", Colors.RED)
            log("", "Check App Store Connect for details", Colors.YELLOW)
            return None

        # Check timeout
        elapsed = time.time() - start_time
        if elapsed > max_wait_seconds:
            log("", f"Timeout after {max_wait_minutes} minutes", Colors.YELLOW)
            log("", f"Build {version} is still processing. Run this script again later:", Colors.YELLOW)
            log("", f"  ./submit_to_app_store.py {version}", Colors.CYAN)
            return None

        # Wait before next check (30 seconds for specific build, 5s when searching)
        time.sleep(30 if target_build and processing_state != "PROCESSING" else 5)


def get_or_create_version(app_id, version_string, dry_run=False):
    """Get existing or create new App Store version"""
    log("", f"Looking for version {version_string}...", Colors.CYAN)

    # Check if version exists
    response = make_api_request(
        "GET",
        f"/apps/{app_id}/appStoreVersions?filter[platform]=IOS&filter[versionString]={version_string}"
    )

    if not response:
        return None

    if response.get('data'):
        version_id = response['data'][0]['id']
        state = response['data'][0]['attributes'].get('appStoreState', 'UNKNOWN')
        log("", f"Found existing version: {version_string} (State: {state})", Colors.GREEN)

        # Check if already submitted
        if state in ['WAITING_FOR_REVIEW', 'IN_REVIEW', 'PENDING_DEVELOPER_RELEASE', 'READY_FOR_SALE']:
            log("", f"Version already in state: {state}", Colors.YELLOW)
            log("", "Skipping submission (already submitted)", Colors.YELLOW)
            return None

        return version_id

    # Create new version
    if dry_run:
        log("", f"[DRY RUN] Would create new version {version_string}", Colors.YELLOW)
        return "dry-run-version-id"

    log("", f"Creating new version {version_string}...", Colors.CYAN)
    data = {
        "data": {
            "type": "appStoreVersions",
            "attributes": {
                "platform": "IOS",
                "versionString": version_string
            },
            "relationships": {
                "app": {
                    "data": {"type": "apps", "id": app_id}
                }
            }
        }
    }

    response = make_api_request("POST", "/appStoreVersions", data)

    if not response:
        return None

    version_id = response['data']['id']
    log("", f"Created version: {version_string}", Colors.GREEN)
    return version_id


def link_build_to_version(version_id, build_id, dry_run=False):
    """Link build to App Store version"""
    if dry_run:
        log("", "[DRY RUN] Would link build to version", Colors.YELLOW)
        return True

    log("", "Linking build to version...", Colors.CYAN)

    data = {
        "data": {
            "type": "appStoreVersions",
            "id": version_id,
            "relationships": {
                "build": {
                    "data": {"type": "builds", "id": build_id}
                }
            }
        }
    }

    response = make_api_request("PATCH", f"/appStoreVersions/{version_id}", data)

    if not response:
        return False

    log("", "Build linked to version", Colors.GREEN)
    return True


def add_release_notes_all_locales(version_id, release_notes, dry_run=False):
    """Add or update release notes for ALL localizations"""
    if dry_run:
        log("", f"[DRY RUN] Would add release notes to all locales: \"{release_notes}\"", Colors.YELLOW)
        return True

    log("", "Adding release notes for all localizations...", Colors.CYAN)

    # Get all existing localizations
    response = make_api_request(
        "GET",
        f"/appStoreVersions/{version_id}/appStoreVersionLocalizations"
    )

    if not response:
        return False

    localizations = response.get('data', [])

    if not localizations:
        log("", "No localizations found", Colors.YELLOW)
        return False

    success_count = 0
    total_count = len(localizations)

    for loc in localizations:
        locale_code = loc['attributes']['locale']
        loc_id = loc['id']

        # Update existing localization with release notes
        data = {
            "data": {
                "type": "appStoreVersionLocalizations",
                "id": loc_id,
                "attributes": {"whatsNew": release_notes}
            }
        }

        response = make_api_request("PATCH", f"/appStoreVersionLocalizations/{loc_id}", data)

        if response:
            log("", f"Added release notes for {locale_code}", Colors.GREEN)
            success_count += 1
        else:
            log("", f"Failed to add release notes for {locale_code}", Colors.YELLOW)

    if success_count == total_count:
        log("", f"Release notes added to all {total_count} localizations", Colors.GREEN)
        return True
    elif success_count > 0:
        log("", f"Release notes added to {success_count}/{total_count} localizations", Colors.YELLOW)
        return True
    else:
        log("", "Failed to add release notes to any localization", Colors.RED)
        return False


def submit_for_review(version_id, app_id, dry_run=False):
    """Submit App Store version for review using the new reviewSubmissions API"""
    if dry_run:
        log("", "[DRY RUN] Would submit for review", Colors.YELLOW)
        return True

    log("", "Submitting for review...", Colors.CYAN)

    # Step 1: Create a review submission
    log("   ", "Creating review submission...", Colors.CYAN)
    create_data = {
        "data": {
            "type": "reviewSubmissions",
            "relationships": {
                "app": {
                    "data": {"type": "apps", "id": app_id}
                }
            }
        }
    }

    response = make_api_request("POST", "/reviewSubmissions", create_data)
    if not response:
        # Try the legacy endpoint as fallback
        log("   ", "Trying legacy submission endpoint...", Colors.YELLOW)
        return submit_for_review_legacy(version_id)

    submission_id = response['data']['id']
    log("   ", f"Created review submission: {submission_id}", Colors.GREEN)

    # Step 2: Add the version to the submission
    log("   ", "Adding version to submission...", Colors.CYAN)
    item_data = {
        "data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {
                    "data": {"type": "reviewSubmissions", "id": submission_id}
                },
                "appStoreVersion": {
                    "data": {"type": "appStoreVersions", "id": version_id}
                }
            }
        }
    }

    response = make_api_request("POST", "/reviewSubmissionItems", item_data)
    if not response:
        log("", "Failed to add version to submission", Colors.YELLOW)
        log("", "Please submit manually via App Store Connect", Colors.YELLOW)
        return False

    # Step 3: Confirm/submit the review submission
    log("   ", "Confirming submission...", Colors.CYAN)
    confirm_data = {
        "data": {
            "type": "reviewSubmissions",
            "id": submission_id,
            "attributes": {
                "submitted": True
            }
        }
    }

    response = make_api_request("PATCH", f"/reviewSubmissions/{submission_id}", confirm_data)
    if not response:
        log("", "Failed to confirm submission", Colors.YELLOW)
        log("", "Please submit manually via App Store Connect", Colors.YELLOW)
        return False

    log("", "Submitted for review!", Colors.GREEN)
    return True


def submit_for_review_legacy(version_id):
    """Legacy submission endpoint (fallback)"""
    data = {
        "data": {
            "type": "appStoreVersionSubmissions",
            "relationships": {
                "appStoreVersion": {
                    "data": {"type": "appStoreVersions", "id": version_id}
                }
            }
        }
    }

    response = make_api_request("POST", "/appStoreVersionSubmissions", data)

    if not response:
        log("", "Submission failed - may require manual action", Colors.YELLOW)
        log("", "Please check App Store Connect and submit manually", Colors.YELLOW)
        return False

    log("", "Submitted for review!", Colors.GREEN)
    return True


def main():
    """Main automation workflow"""
    parser = argparse.ArgumentParser(
        description='Automate App Store Connect submission',
        epilog='Built by Filip Kowalski | @filippkowalski | fkowalski.com'
    )
    parser.add_argument('version', help='Version string (e.g., 1.13.0 or 1.13.0+30)')
    parser.add_argument('--project-path', help='Path to Flutter project', default=os.getcwd())
    parser.add_argument('--dry-run', action='store_true', help='Preview without making changes')
    parser.add_argument('--bundle-id', help='Override bundle ID detection')

    args = parser.parse_args()

    print(f"{Colors.CYAN}{'=' * 60}{Colors.NC}")
    print(f"{Colors.CYAN}App Store Connect Automation{Colors.NC}")
    print(f"{Colors.CYAN}Built by Filip Kowalski | @filippkowalski | fkowalski.com{Colors.NC}")
    print(f"{Colors.CYAN}{'=' * 60}{Colors.NC}")

    # Check environment variables first
    check_environment_variables()

    if args.dry_run:
        log("", "DRY RUN MODE - No changes will be made", Colors.YELLOW)
        print()

    # Parse version string to extract version and build number
    # Format: 1.13.0+30 or just 1.13.0
    version_string = args.version
    build_number = None

    if '+' in version_string:
        version_part, build_number = version_string.split('+')
        log("", f"Parsed: Version {version_part}, Build {build_number}", Colors.BLUE)
    else:
        version_part = version_string
        log("", f"Version {version_part} (no specific build number)", Colors.BLUE)

    print()

    # 1. Detect or use provided bundle ID
    bundle_id = args.bundle_id or find_bundle_id(args.project_path)
    if not bundle_id:
        log("", "Could not detect bundle ID. Use --bundle-id to specify manually", Colors.RED)
        sys.exit(1)

    print()

    # 2. Find app
    app_id = find_app_by_bundle_id(bundle_id)
    if not app_id:
        sys.exit(1)

    print()

    # 3. Wait for build to be ready (with specific build number if provided)
    build_id = wait_for_build_processing(app_id, expected_build_number=build_number, dry_run=args.dry_run)
    if not build_id:
        sys.exit(1)

    print()

    # 4. Get or create version (use version part only, without build number)
    version_id = get_or_create_version(app_id, version_part, dry_run=args.dry_run)
    if not version_id:
        if not args.dry_run:
            log("", "Version may already be submitted", Colors.YELLOW)
        sys.exit(0)  # Not an error, just already done

    print()

    # 5. Link build to version
    if not link_build_to_version(version_id, build_id, dry_run=args.dry_run):
        sys.exit(1)

    print()

    # 6. Add release notes to ALL localizations
    if not add_release_notes_all_locales(version_id, RELEASE_NOTES, dry_run=args.dry_run):
        sys.exit(1)

    print()

    # 7. Submit for review
    submission_success = submit_for_review(version_id, app_id, dry_run=args.dry_run)

    print()
    print(f"{Colors.CYAN}{'=' * 60}{Colors.NC}")
    if args.dry_run:
        log("", "DRY RUN COMPLETE - No changes were made", Colors.YELLOW)
    elif submission_success:
        log("", "Success! App submitted for review", Colors.GREEN)
    else:
        log("", "Setup complete, but submission requires manual action", Colors.YELLOW)
        log("", "Version created and configured - please submit via App Store Connect", Colors.YELLOW)
    print(f"{Colors.CYAN}{'=' * 60}{Colors.NC}")
    print()
    log("", f"Version: {version_part}" + (f" (Build {build_number})" if build_number else ""), Colors.BLUE)
    log("", f"Release notes: {RELEASE_NOTES}", Colors.BLUE)
    log("", "View status: https://appstoreconnect.apple.com", Colors.BLUE)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
        log("", "Interrupted by user", Colors.YELLOW)
        sys.exit(130)
    except Exception as e:
        print()
        log("", f"Unexpected error: {e}", Colors.RED)
        sys.exit(1)
