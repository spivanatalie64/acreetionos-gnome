#!/usr/bin/env python3
"""Opening install-mode screen and isolated Calamares configuration profiles."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import hardware_detect
except ImportError:
    hardware_detect = None

try:
    import migration_backup
except ImportError:
    migration_backup = None


DOWNLOAD_JOBS = {
    'shellprocess@base', 'shellprocess@nvidia-autodetect',
    'shellprocess@amd-autodetect', 'shellprocess@intel-autodetect',
    'packages', 'netinstall@drivers', 'netinstall@software',
}


def sync_timezone_and_location():
    """Attempt automatic timezone detection and synchronization via GeoIP."""
    try:
        req = urllib.request.Request(
            "https://geoip.kde.org/v1/calamares",
            headers={"User-Agent": "AcreetionOS-Installer"}
        )
        with urllib.request.urlopen(req, timeout=2) as resp:
            data = json.loads(resp.read().decode())
            tz = data.get("time_zone") or data.get("timezone")
            if tz:
                subprocess.run(["timedatectl", "set-timezone", tz], stderr=subprocess.DEVNULL)
    except Exception:
        pass


def prepare_profile(source, destination, mode, auto_drivers=False):
    """Build a fresh profile; offline never queues a package download job."""
    if mode not in ('online', 'offline'):
        raise ValueError('Choose online or offline')
    source, destination = Path(source), Path(destination)
    shutil.copytree(source, destination, dirs_exist_ok=True)
    settings_path = destination / 'settings.conf'
    settings = yaml.safe_load(settings_path.read_text())
    for phase in settings['sequence']:
        for kind, steps in phase.items():
            phase[kind] = [step for step in steps if step not in DOWNLOAD_JOBS]
    if mode == 'online':
        show = settings['sequence'][0]['show']
        show[show.index('summary'):show.index('summary')] = [
            'netinstall@drivers', 'netinstall@software']
        jobs = next(phase['exec'] for phase in settings['sequence'] if 'exec' in phase)
        # Install chosen kernels/drivers before generating the initramfs.
        jobs.insert(jobs.index('initcpiocfg'), 'packages')
        if auto_drivers:
            position = jobs.index('initcpiocfg')
            jobs[position:position] = [
                f'shellprocess@{vendor}-autodetect'
                for vendor in ('nvidia', 'amd', 'intel')
            ]
        package_path = destination / 'modules/packages.conf'
        packages = yaml.safe_load(package_path.read_text())
        packages.update(backend='pacman', skip_if_no_internet=False,
                        update_db=True, update_system=False)
        package_path.write_text(yaml.safe_dump(packages, sort_keys=False))
        for name in ('drivers', 'software'):
            catalogue = destination / f'modules/{name}.yaml'
            groups = yaml.safe_load(catalogue.read_text())
            def reveal(items):
                for group in items:
                    group['hidden'] = False
                    reveal(group.get('subgroups', []))
            reveal(groups)
            catalogue.write_text(yaml.safe_dump(groups, sort_keys=False))
            config_path = destination / f'modules/net_{name}.conf'
            config = yaml.safe_load(config_path.read_text())
            config['groupsUrl'] = catalogue.as_uri()
            config_path.write_text(yaml.safe_dump(config, sort_keys=False))

        if auto_drivers and hardware_detect:
            try:
                hw = hardware_detect.detect_all_hardware()
                hardware_detect.apply_hardware_to_drivers_catalogue(
                    destination / 'modules/drivers.yaml', hw)
            except Exception:
                pass

        welcome_path = destination / 'modules/welcome.conf'
        welcome = yaml.safe_load(welcome_path.read_text())
        for key in ('check', 'required'):
            if 'internet' not in welcome['requirements'][key]:
                welcome['requirements'][key].append('internet')
        welcome_path.write_text(yaml.safe_dump(welcome, sort_keys=False))
    settings_path.write_text(yaml.safe_dump(settings, sort_keys=False))


def choose_mode():
    import gi
    gi.require_version('Gtk', '3.0')
    from gi.repository import Gdk, Gtk

    css = Gtk.CssProvider()
    css.load_from_data(b'''
        window { background: #25252d; color: #faf7ef; }
        label { color: #faf7ef; }
        .eyebrow { color: #c9bfa9; font-size: 12px; letter-spacing: 3px; }
        .heading { font-size: 36px; font-weight: 800; }
        .muted { color: #c5c1b9; font-size: 15px; }
        button.card { border: 1px solid #5b574e; border-radius: 24px;
            padding: 30px; box-shadow: 0 12px 24px alpha(black, 0.2);
            background-image: linear-gradient(145deg, #49453d, #34323a); }
        button.offline { background-image: linear-gradient(145deg, #3c3c46, #31313a); }
        button.card:hover { border-color: #ebe0c9; background-color: #49453d; }
        button.card:focus { outline: 3px solid #ebe0c9; outline-offset: 4px; }
        .card-title { font-size: 30px; font-weight: 700; }
        .card-icon { color: #ebe0c9; margin-bottom: 12px; }
        .action { color: #ebe0c9; font-size: 16px; font-weight: 700; margin-top: 16px; }
        button.cancel { background: transparent; border: none; box-shadow: none;
            color: #c5c1b9; padding: 10px 24px; }
    ''')
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    window = Gtk.Window(title='Install AcreetionOS')
    window.set_default_size(1060, 680)
    window.set_position(Gtk.WindowPosition.CENTER)
    result = []
    window.connect('destroy', lambda *_: Gtk.main_quit())
    scroll = Gtk.ScrolledWindow()
    scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
    window.add(scroll)
    content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
    content.set_border_width(40)
    content.set_valign(Gtk.Align.CENTER)
    scroll.add(content)

    def label(text, style, parent, centered=False):
        widget = Gtk.Label(label=text)
        widget.set_line_wrap(True)
        widget.set_max_width_chars(38)
        widget.set_xalign(0.5 if centered else 0)
        widget.get_style_context().add_class(style)
        parent.pack_start(widget, False, False, 0)
        return widget

    label('ACREETIONOS  /  INSTALLATION', 'eyebrow', content, True)
    label('Your system. Your starting point.', 'heading', content, True)
    label('Choose how you would like to install.', 'muted', content, True)
    cards = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=24, homogeneous=True)
    cards.set_margin_top(16)
    cards.set_margin_bottom(12)
    # Keep Online left and Offline right in every locale.
    cards.set_direction(Gtk.TextDirection.LTR)
    content.pack_start(cards, True, True, 0)

    def select(_button, mode):
        auto_drivers = False
        if mode == 'online':
            hw_summary = ""
            if hardware_detect:
                try:
                    hw = hardware_detect.detect_all_hardware()
                    hw_summary = hardware_detect.format_driver_summary(hw)
                except Exception:
                    pass

            # --- Check 1 of 2: Hardware detection and driver setup proposal ---
            dialog = Gtk.Dialog(title='Hardware Drivers (Check 1 of 2)', transient_for=window, modal=True)
            dialog.set_default_size(680, 480)
            dialog.add_button('Back', Gtk.ResponseType.CANCEL)
            dialog.add_button("I'll choose drivers myself", Gtk.ResponseType.NO)
            dialog.add_button('Yes, install drivers for me', Gtk.ResponseType.YES)
            body = dialog.get_content_area()
            body.set_border_width(28)
            body.set_spacing(14)
            label('Hardware Detected & Driver Setup (Check 1 of 2)', 'card-title', body)
            label('AcreetionOS analyzed your hardware configuration:', 'muted', body)
            if hw_summary:
                scroll_hw = Gtk.ScrolledWindow()
                scroll_hw.set_min_content_height(140)
                scroll_hw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
                hw_lbl = Gtk.Label(label=hw_summary)
                hw_lbl.set_xalign(0)
                hw_lbl.set_line_wrap(True)
                scroll_hw.add(hw_lbl)
                body.pack_start(scroll_hw, True, True, 0)
            else:
                label('NVIDIA, AMD, Intel graphics and CPU microcode detection ready.', 'muted', body)
            label('Would you like AcreetionOS to automatically configure and pre-select the matching drivers for you in Calamares?',
                  'muted', body)
            label('This should work fine for most systems. Some specialized hardware may not work quite as well and may need a little extra help.',
                  'muted', body)
            support = label('', 'muted', body)
            support.set_markup('If you run into trouble, come to '
                               '<a href="https://discord.acreetionos.org">'
                               'discord.acreetionos.org</a> '
                               "and we'll help you figure it out &lt;3")
            label('You can also review and customize driver choices inside Calamares.',
                  'muted', body)
            dialog.show_all()
            response = dialog.run()
            dialog.destroy()
            if response not in (Gtk.ResponseType.YES, Gtk.ResponseType.NO):
                return

            if response == Gtk.ResponseType.YES:
                verify_dialog = Gtk.Dialog(title='Driver Verification (Check 2 of 2)', transient_for=window, modal=True)
                verify_dialog.set_default_size(640, 400)
                verify_dialog.add_button('Back / Change', Gtk.ResponseType.NO)
                verify_dialog.add_button('Confirm & Proceed', Gtk.ResponseType.YES)
                vbody = verify_dialog.get_content_area()
                vbody.set_border_width(28)
                vbody.set_spacing(14)
                label('Please Double-Check & Confirm (Check 2 of 2)', 'card-title', vbody)
                label('Please confirm that you want Calamares to install the recommended drivers:', 'muted', vbody)
                if hw_summary:
                    v_scroll = Gtk.ScrolledWindow()
                    v_scroll.set_min_content_height(120)
                    v_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
                    v_lbl = Gtk.Label(label=hw_summary)
                    v_lbl.set_xalign(0)
                    v_lbl.set_line_wrap(True)
                    v_scroll.add(v_lbl)
                    vbody.pack_start(v_scroll, True, True, 0)
                label('Click "Confirm & Proceed" to continue with this driver plan, or "Back / Change" to choose drivers yourself.', 'muted', vbody)
                verify_dialog.show_all()
                v_resp = verify_dialog.run()
                verify_dialog.destroy()
                if v_resp == Gtk.ResponseType.YES:
                    auto_drivers = True
                else:
                    auto_drivers = False
            else:
                auto_drivers = False

        result.append((mode, auto_drivers))
        window.destroy()

    for mode, title, icon, subtitle, detail, action in (
        ('online', 'Online', 'network-wireless-symbolic', 'Make room for more.',
         'Choose from all available software, fonts, kernels and drivers.\n\nAn internet connection is required.',
         'Continue online  \u2192'),
        ('offline', 'Offline', 'drive-harddisk-symbolic', 'Everything you need to begin.',
         'Install the system included on this image. No extra packages or downloads.\n\nNo internet connection needed.',
         'Continue offline  \u2192'),
    ):
        button = Gtk.Button()
        button.get_style_context().add_class('card')
        button.get_style_context().add_class(mode)
        button.get_accessible().set_name(f'{title} installation. {detail}')
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        button.add(box)
        picture = Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.DIALOG)
        picture.set_pixel_size(48)
        picture.set_halign(Gtk.Align.START)
        picture.get_style_context().add_class('card-icon')
        box.pack_start(picture, False, False, 0)
        label(title, 'card-title', box)
        label(subtitle, 'muted', box)
        label(detail, 'muted', box)
        label(action, 'action', box)
        button.connect('clicked', select, mode)
        cards.pack_start(button, True, True, 0)
    label('Both paths install the same AcreetionOS foundation.', 'muted', content, True)
    cancel = Gtk.Button(label='Back to desktop')
    cancel.get_style_context().add_class('cancel')
    cancel.set_halign(Gtk.Align.CENTER)
    cancel.connect('clicked', lambda *_: window.destroy())
    content.pack_start(cancel, False, False, 0)
    window.show_all()
    Gtk.main()
    return result[0] if result else None


def main():
    sync_timezone_and_location()
    if migration_backup:
        try:
            migration_backup.check_and_run_migration()
        except Exception:
            pass

    choice = choose_mode()
    if choice is None:
        return 0
    mode, auto_drivers = choice
    with tempfile.TemporaryDirectory(prefix='calamares-') as directory:
        prepare_profile('/etc/calamares', directory, mode, auto_drivers)
        with open('/root/calamares.log', 'w') as log:
            return subprocess.call(['calamares', '-D', '8', '-c', directory],
                                   stdout=log, stderr=subprocess.STDOUT)


if __name__ == '__main__':
    raise SystemExit(main())
