// The SSH commands screen: tv for the TV, ent for Entware.  Keep in step
// with tv help and ent help (tests/ui-test.js checks every command is here).
window.ENTWARE_COMMANDS = {
    tv: {
        title: 'tv: the TV',
        lead: 'Apps, the screen, the system, files and automation.  On its own, tv shows how the TV is doing and what\'s on screen.',
        groups: [
            ['Overview', [
                ['tv', 'How the TV is doing, what\'s on screen, and a line about Entware'],
                ['tv info', 'Model, webOS, network, CPU, memory and storage']
            ]],
            ['Apps', [
                ['tv apps [-a] [text]', 'Apps and their IDs (* running)'],
                ['tv launch <id>', 'Start an app'],
                ['tv close <id>', 'Close an app'],
                ['tv running', 'What\'s running, and what\'s on screen'],
                ['tv app install <ipk|url>', 'Install an app package'],
                ['tv app uninstall <id>', 'Remove an app you installed'],
                ['tv open <url>', 'Open a page in the TV\'s browser'],
                ['tv youtube <link|id>', 'Play a video in YouTube']
            ]],
            ['The screen', [
                ['tv toast <message>', 'Show a notification on the TV'],
                ['tv shot [file]', 'Screenshot what\'s on screen'],
                ['tv volume [up|down|0-100]', 'Read or change the volume'],
                ['tv mute [on|off]', 'Mute or unmute (on its own, like the remote\'s button)'],
                ['tv input [list|hdmi1-4]', 'The inputs, what\'s plugged in, and switching'],
                ['tv screen off|on', 'Turn the picture off or on, with the TV still running'],
                ['tv power off', 'Turn the TV off (asks first)'],
                ['tv reboot', 'Restart the TV (asks first)'],
                ['tv settings get|set', 'Picture, sound and other settings, like: tv settings set picture backlight=40']
            ]],
            ['System', [
                ['tv top', 'CPU, memory and the busiest processes'],
                ['tv temp', 'How hot the chip is, on TVs that report it'],
                ['tv space [clean]', 'What\'s using storage, and safe things to clear'],
                ['tv ports', 'What\'s listening on the network, and which program'],
                ['tv logs [boot|tasks|text]', 'The system log, the boot log or this app\'s tasks'],
                ['tv net [test|speed <host>]', 'Network details, a connection test, a speed test'],
                ['tv wake <mac>', 'Wake another device on the network'],
                ['tv usb [eject <drive>]', 'USB drives, and unplugging one safely'],
                ['tv report', 'What to put in a GitHub issue']
            ]],
            ['Files', [
                ['tv serve [folder] [port]', 'Share a folder over HTTP, with a QR code for your phone'],
                ['tv qr <text>', 'Show text or a link as a QR code'],
                ['tv backup [where]', 'Save your settings, add-ons, packages and keys (to USB if plugged in)'],
                ['tv restore <file>', 'Put a backup back']
            ]],
            ['Automation', [
                ['tv autostart [list|add|on|off|remove|show]', 'Scripts that run when the TV starts'],
                ['tv keys [list|add|remove]', 'Who can log in over SSH.  tv keys add <github-user> adds their keys'],
                ['tv done <command>', 'Run a command, then pop up on the TV when it\'s done']
            ]]
        ]
    },
    ent: {
        title: 'ent: Entware',
        lead: 'Packages, add-ons and services.  On its own, ent shows how Entware is doing.  Anything else goes straight to opkg.',
        groups: [
            ['Packages', [
                ['ent search <word>', 'Search Entware\'s packages'],
                ['ent show <pkg>', 'All about one package: description, size, what it adds'],
                ['ent install <pkg>...', 'Install packages, with the webOS setup some need'],
                ['ent remove <pkg>...', 'Remove packages (not ones Entware needs)'],
                ['ent browse [category]', 'Packages by category, like Browse in this app'],
                ['ent list [text]', 'What\'s installed'],
                ['ent files <pkg>', 'The files a package installed'],
                ['ent owns <file|cmd>', 'Which package a file or command came from'],
                ['ent why <pkg>', 'What needs a package'],
                ['ent du [count]', 'The biggest installed packages, and free space'],
                ['ent cleanup', 'Remove packages nothing needs any more'],
                ['ent update', 'Refresh the package list'],
                ['ent upgrade [pkg]', 'Update everything, or one package'],
                ['ent upgradable', 'What has an update'],
                ['ent repair', 'Reinstall Entware\'s core']
            ]],
            ['Add-ons and services', [
                ['ent addon [list]', 'The add-ons and their state'],
                ['ent addon add|remove <name>', 'Add or remove one, with its setup'],
                ['ent addon info <name>', 'Its address and password'],
                ['ent addon password <name>', 'A new password'],
                ['ent svc [list]', 'Entware\'s services and whether they run'],
                ['ent svc start|stop|restart <name>', 'Start, stop or restart one'],
                ['ent svc enable|disable <name>', 'Start it at boot, or not'],
                ['ent svc logs <name>', 'What it logged'],
                ['ent share', 'Every address for File Browser, Samba and the rest']
            ]],
            ['Checks', [
                ['ent', 'How Entware is doing'],
                ['ent where <command>', 'Where a command comes from, and which one runs'],
                ['ent doctor', 'Check Entware and the TV, and say what to fix']
            ]]
        ]
    }
};
