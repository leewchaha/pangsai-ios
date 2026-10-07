"""Linux-runnable unit tests for the Codemagic provisioning preflight."""
import importlib.util
import io
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'verify_signing_profiles.py'
spec = importlib.util.spec_from_file_location('verify_signing_profiles', MODULE)
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


def profile(bundle, *, group=True, team='56T7HW68RT', app_store=True, cloudkit=True, apns=True, name=None):
    ent = {
        'application-identifier': team + '.' + bundle,
        'com.apple.security.application-groups': [preflight.APP_GROUP] if group else [],
        'get-task-allow': not app_store,
    }
    if bundle == preflight.APP_ID:
        ent['com.apple.developer.icloud-container-identifiers'] = ([preflight.ICLOUD_CONTAINER] if cloudkit else [])
        ent['com.apple.developer.icloud-services'] = ['CloudKit'] if cloudkit else []
        ent['aps-environment'] = 'production' if apns else 'development'
    return {
        'Name': name or bundle + ' AppStore', 'UUID': 'uuid-' + bundle,
        'TeamIdentifier': [team], 'Entitlements': ent,
        'ExpirationDate': datetime.now(timezone.utc) + timedelta(days=200),
    }


def assignments(app_name=None, ext_name=None, team='56T7HW68RT'):
    return {
        'ShittyFriends': {
            'PRODUCT_BUNDLE_IDENTIFIER': preflight.APP_ID,
            'CODE_SIGN_STYLE': 'Manual',
            'PROVISIONING_PROFILE_SPECIFIER': app_name or preflight.APP_ID + ' AppStore',
            'DEVELOPMENT_TEAM': team,
        },
        'NotificationService': {
            'PRODUCT_BUNDLE_IDENTIFIER': preflight.EXTENSION_ID,
            'CODE_SIGN_STYLE': 'Manual',
            'PROVISIONING_PROFILE_SPECIFIER': ext_name or preflight.EXTENSION_ID + ' AppStore',
            'DEVELOPMENT_TEAM': team,
        },
    }


class SigningProfileTests(unittest.TestCase):
    def setUp(self):
        self.good = [profile(preflight.APP_ID), profile(preflight.EXTENSION_ID)]

    def errors(self, profiles, builds=None):
        with redirect_stdout(io.StringIO()):
            return preflight.inspect(profiles, builds)

    def test_two_valid_installed_profiles(self):
        self.assertEqual(self.errors(self.good), [])

    def test_two_valid_profiles_and_release_assignments(self):
        self.assertEqual(self.errors(self.good, assignments()), [])

    def test_extension_group_missing(self):
        profiles = [self.good[0], profile(preflight.EXTENSION_ID, group=False)]
        self.assertIn('App Groups entitlement missing', '\n'.join(self.errors(profiles)))

    def test_missing_extension_profile(self):
        self.assertIn('No installed', '\n'.join(self.errors([self.good[0]])))

    def test_main_missing_cloudkit_and_push(self):
        profiles = [profile(preflight.APP_ID, cloudkit=False, apns=False), self.good[1]]
        err = '\n'.join(self.errors(profiles))
        self.assertIn('CloudKit', err)
        self.assertIn('Push Notifications', err)

    def test_wrong_distribution_type(self):
        profiles = [self.good[0], profile(preflight.EXTENSION_ID, app_store=False)]
        self.assertIn('not a distribution', '\n'.join(self.errors(profiles)))

    def test_expired_profile(self):
        expired = profile(preflight.EXTENSION_ID)
        expired['ExpirationDate'] = datetime.now(timezone.utc) - timedelta(days=1)
        self.assertIn('expired', '\n'.join(self.errors([self.good[0], expired])))

    def test_old_assigned_profile_rejected_even_with_valid_profile_present(self):
        stale = profile(preflight.EXTENSION_ID, group=False, name='old extension profile')
        err = '\n'.join(self.errors(self.good + [stale], assignments(ext_name='old extension profile')))
        self.assertIn('Assigned profile', err)
        self.assertIn('App Groups entitlement missing', err)

    def test_release_assignment_wrong_team_rejected(self):
        err = '\n'.join(self.errors(self.good, assignments(team='WRONGTEAM0')))
        self.assertIn('wrong Apple team', err)

    def test_release_assignment_missing_rejected(self):
        settings = assignments()
        settings['NotificationService']['PROVISIONING_PROFILE_SPECIFIER'] = ''
        self.assertIn('No profile assigned', '\n'.join(self.errors(self.good, settings)))

    def test_release_assignment_not_manual_rejected(self):
        settings = assignments()
        settings['NotificationService']['CODE_SIGN_STYLE'] = 'Automatic'
        self.assertIn('not Manual', '\n'.join(self.errors(self.good, settings)))

    def test_app_group_consistency(self):
        self.assertEqual(preflight.APP_GROUP, 'group.com.sakara.shittyfriends')

    def test_empty_profile_folder_fails_before_archive(self):
        with tempfile.TemporaryDirectory() as folder:
            with redirect_stdout(io.StringIO()):
                import contextlib
                with contextlib.redirect_stderr(io.StringIO()):
                    result = preflight.main(['--profiles-dir', folder])
            self.assertEqual(result, 2)


if __name__ == '__main__':
    unittest.main()
