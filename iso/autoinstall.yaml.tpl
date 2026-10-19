# Scrappy worker — Ubuntu 24.04.5 autoinstall config (template).
#
# build.sh renders this into the nocloud seed /scrappy/user-data on the ISO
# (plus an empty /scrappy/meta-data). Only the two Scrappy GRUB entries point
# cloud-init at it (ds=nocloud;s=/cdrom/scrappy/); there is no /autoinstall.yaml
# at the ISO root, so the manual-installer entry stays interactive.
#   @PASSWORD_HASH@  <- iso/config.local (never committed)
#   @SSH_KEYS@       <- iso/keys/authorized_keys; the single placeholder item
#                       is replaced by one list item per key (comments and
#                       blank lines dropped)
# __SCRAPPY_TARGET_DISK__ is NOT a build placeholder: pick-disk.sh replaces it
# at install time in the running installer's /autoinstall.yaml (subiquity
# copies the cloud-config autoinstall there). If that never happens, the
# storage match fails and the installer stops before touching any disk.
#
# Keep `autoinstall` the ONLY top-level key: any other cloud-config key would
# be applied by cloud-init to the live installer system itself.

autoinstall:
  version: 1
  interactive-sections: []
  refresh-installer:
    update: false

  locale: en_US.UTF-8
  keyboard:
    layout: hu
  timezone: Europe/Budapest

  # No `network:` section on purpose. Subiquity defaults to DHCP on the
  # wired interfaces and then does not run its own `netplan apply` with our
  # config. That apply raced with disk probing in testing (D-Bus "Connection
  # timed out") and aborted the install. The installed system's netplan
  # config (match en*, dhcp4, optional) is written by late.sh instead; a
  # late-plugged cable is handled there by scrappy-firstboot.

  # LVM over the whole disk (sizing-policy: all -> ubuntu-lv gets 100%,
  # not the stock 50%).
  storage:
    layout:
      name: lvm
      sizing-policy: all
      match:
        path: __SCRAPPY_TARGET_DISK__

  identity:
    hostname: scrappy-worker-new   # replaced on first boot from the MAC
    realname: Kevin
    username: kevin
    password: "@PASSWORD_HASH@"

  ssh:
    install-server: true
    allow-pw: false
    authorized-keys:
      - "@SSH_KEYS@"

  packages:
    - ca-certificates
    - curl
    - jq
    - unattended-upgrades

  updates: all

  # Power off instead of rebooting: "it switched itself off" = done.
  # Pull the pendrive, power on.
  shutdown: poweroff

  early-commands:
    - bash /cdrom/scrappy/pick-disk.sh

  late-commands:
    - bash /cdrom/scrappy/late.sh
