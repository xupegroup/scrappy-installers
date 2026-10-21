# Scrappy worker — autoinstall ISO (Ubuntu 24.04.5)

Pendrive-ra írható ISO, amellyel egy mini-PC-ből kézi telepítés nélkül Scrappy worker lesz. Első induláskor a gép jelentkezik az API-nál. Az admin felületen (`/admin/workers`) jóváhagyod, és a gép a saját titkával felveszi a worker-tokent. Tokenmásolás és SSH nem kell. A kézi út (`install-worker.sh` + token) tartaléknak megmarad.

> ⚠️ **Az alapértelmezett menüpont kérdés nélkül törli a belső lemezt, ha azon nincs Linux.** A pendrive-ot címkézd fel: „SCRAPPY WORKER – TÖRLI A LEMEZT”.

## Mit csinál

- Magyar billentyűzet, `Europe/Budapest` időzóna, DHCP minden ethernet-porton.
- LVM a belső lemez **teljes** méretén, vagyis az `ubuntu-lv` nem csak a lemez felét kapja.
- `kevin` user YubiKey-es SSH-val. A jelszavas SSH ki van kapcsolva, konzolon a sudo-jelszóval lehet belépni.
- Frissítések már telepítéskor, unattended-upgrades, automatikus újraindítás 04:00-kor.
- `Prompt=never`: nem ajánlja fel a 26.04-re frissítést.
- A telepítés végén a gép **kikapcsol**. Ez jelzi, hogy kész.
- Első induláskor a `scrappy-firstboot` beállítja a hostnevet (`scrappy-worker-` + a MAC-cím utolsó 6 hex jegye), és feltelepíti a Dockert a hivatalos apt-repóból.
- Utána a `scrappy-register` önregisztrál (lásd lent), majd jóváhagyás után lefuttatja az `install-worker.sh`-t.
- A `scrappy-inventory` a hoston összegyűjti a leltárt (gyártó, CPU, RAM, lemezek, MAC-ek, OS) az `/opt/scrappy/host-info/inventory.json`-ba, bootkor és naponta. A worker ezt küldi a heartbeattel.

Az ISO-ban nincs titok, csak publikus kulcs, a sudo-jelszó hash-e és az API címe. A worker-token soha nem kerül az ISO-ra. A gép a titkát első induláskor maga generálja.

## Build (WSL2 + Docker)

Egyszer kell:

```bash
sudo apt install -y make
cp iso/config.local.example iso/config.local
make passwd-hash
```

A `make passwd-hash` bekéri a jelszót, és kiírja a yescrypt hash-t. A hash-t írd be az `iso/config.local` fájl `PASSWORD_HASH='...'` sorába, egyszeres idézőjelek közé. Az `iso/config.local` gitignore-olt, soha ne commitold.

Build:

```bash
make iso
```

Az eredmény: `out/scrappy-worker-24.04.5-<git-sha>.iso`, mellette a `.sha256` fájl.

A build menete:
1. Letölti az Ubuntu ISO-t a `build/cache/` mappába, ha még nincs ott.
2. Ellenőrzi a `SHA256SUMS` gpg-aláírását és az ISO checksumát.
3. Rendereli a `user-data`-t.
4. Xorrisóval újracsomagolja az ISO-t, megtartva a UEFI- és a BIOS-bootot.

A `make lint` letöltés nélkül futtat shellchecket, renderelést és grub-ellenőrzést.

Az API címe, ahová a gépek regisztrálnak, az `iso/config.local` `API_BASE_URL=` sorából jön (alapértelmezés `https://api.scrappy.hu`), vagy parancssorból: `make iso API_BASE_URL=https://...`. Nem titok, a gépen az `/etc/scrappy/register.env`-be kerül.
- Csak `https://host[:port]` fogadható el. Sima `http://` csak `ALLOW_HTTP_API=1` mellett megy, ez a lokális QEMU-teszthez kell.
- Ha a cím nem az alapértelmezett, az ISO neve `-devapi` utótagot kap, így egy teszt-ISO nem keverhető össze az élessel.

SSH-kulcsot az `iso/keys/authorized_keys` fájlban lehet hozzáadni, soronként egyet. A `#`-kal kezdődő és az üres sorokat a build kihagyja.

## Pendrive-írás (Windows)

Két bevált eszköz:

- **Rufus:** válaszd ki az ISO-t, és amikor rákérdez, a **„DD Image” módot** válaszd, ne az ISO módot.
- **Raspberry Pi Imager:** Operating System → **„Use custom”** → az ISO kiválasztása → Storage → a pendrive → Write.

**Írás után ellenőrizd a pendrive-ot.** A telepítő nem vizsgálja a médiát (`fsck.mode=skip`, lásd a GRUB-menüt), így egy hibásan megírt pendrive csak telepítés közbeni hibaként derülne ki. Ezért a **Raspberry Pi Imager** az ajánlott: írás után magától visszaolvassa és ellenőrzi a pendrive-ot („Verifying”). A Rufus DD módban nem ellenőriz; ha azzal írtál, és a telepítés megmagyarázhatatlanul elakad, írd újra a pendrive-ot Imagerrel.

Az ISO elérési útja Windowsból:

```
\\wsl.localhost\<disztró>\home\kevin\projects\scrappy-installers\out\
```

A `<disztró>` helyére a WSL-disztró neve kerül. A neveket PowerShellben ez a parancs listázza:

```powershell
wsl -l
```

## Boot menü

| Menüpont | Mikor |
|---|---|
| **Scrappy worker – új telepítés** (alapértelmezett, 10 mp után indul) | új gép: üres vagy gyári Windowsos lemez |
| **ÚJRATELEPÍTÉS: FELÜLÍRJA A MEGLÉVŐ LINUXOT** | régi worker újratelepítése; kézzel kell kiválasztani |
| Ubuntu Server – kézi telepítő | mentőút, autoinstall nélkül, minden kérdést feltesz |

Csak az első két menüpont tölti be a Scrappy configot (`ds=nocloud;s=/cdrom/scrappy/`). A harmadik az eredeti, interaktív Ubuntu-telepítő.

### Mikor áll meg az új telepítés?

Az alapértelmezett menüpont **csak akkor telepít, ha a belső lemezen nincs Linux.** Megáll, ha a lemezen vagy bármelyik partícióján ezek közül bármi van:

- LVM physical volume, például `ubuntu-vg`.
- Linux-típusú partíció. GPT-n: Linux filesystem, LVM, swap, RAID, root, home vagy srv típus. MBR-en: 0x83, 0x8e, 0x82 vagy 0xfd.
- ext2/3/4, xfs vagy btrfs fájlrendszer, swap, vagy md RAID tag.

**Üres lemezre és gyári Windowsos lemezre (NTFS, EFI-partíció, MSR, recovery) kérdés nélkül telepít.** Ezek tartalma elvész.

Ha megáll, a képernyőn ez az üzenet jelenik meg, a lemez nevével (például `/dev/nvme0n1`), alatta pedig a lemezlista:

```
A lemezen (/dev/nvme0n1) mar van Linux-telepites. Ujratelepiteshez valaszd a masodik menupontot.
A telepites leallt, egyetlen lemez sem lett torolve.
```

Az üzenet szándékosan ékezet nélküli, mert a konzol nem mindig jeleníti meg az ékezeteket.

Ennek az oka, hogy egy bent felejtett pendrive egy áramszünet után ne törölje le a működő workert, ha a BIOS a pendrive-ról bootol. A worker addig nem indul el, amíg a pendrive bent van, de adat nem vész el.

### Melyik lemezre telepít?

- **Kizárt lemezek:** USB-s és cserélhető lemezek, a telepítő média, valamint a 16 GB-nál kisebbek.
- **Pontosan egy jelölt:** azt választja.
- **Több jelölt:** ha pontosan egy NVMe van köztük, azt választja.
- **Egyébként:** megáll, és nem töröl semmit.

## Telepítés lépésről lépésre

1. BIOS, gépenként egyszer: power on after AC loss, és a boot-sorrend (USB, majd belső lemez).
2. Pendrive be, gép be. 10 mp után indul, kérdés nélkül.
3. Amikor a gép **magától kikapcsol**: pendrive ki, gép be.
4. Első induláskor a `scrappy-firstboot` beállítja a hostnevet és feltelepíti a Dockert. Késve bedugott kábellel is kivárja a hálózatot.
5. Utána a `scrappy-register` jelentkezik az API-nál. A konzol login-képernyőjén megjelenik a **párosítókód** (`Pairing code: XXXX-XXXX`), a hostnév és az IP.
6. Az admin felületen (`/admin/workers` → „Registration requests”) megjelenik a kérés. **Jóváhagyás előtt hasonlítsd össze a kódot a gép képernyőjével.** A duplikált MAC, hostnév vagy kód jelvénnyel látszik.
7. Jóváhagyás után a gép legfeljebb kb. 30 mp-en belül felveszi a tokenjét, és lefuttatja az `install-worker.sh`-t. A konzolon `Status: worker installed and running` áll, a worker megjelenik a flottában.

A konzol `Status:` sora:

| Szöveg | Jelentés | Teendő |
|---|---|---|
| `registering with the Scrappy API` | a regisztráció folyamatban | várj |
| `waiting for approval` + kód | függő kérés (24 óráig) | jóváhagyás az adminban |
| `self-registration is switched off on the server` | az API-n ki van kapcsolva az önregisztráció | kézi út, vagy várj: 10 percenként újrapróbálja |
| `approved, installing the worker` | jóváhagyva, telepít | várj |
| `worker installed and running` | kész | — |
| `registration REJECTED by an admin` | elutasítva, a gép leállt | újratelepítés, vagy kézi út |
| `token was already claimed and is lost` | a token elveszett | token-rotálás az adminban, utána kézi út |

Ha a kérés 24 óráig nem kap döntést, vagy a jóváhagyás után 7 napig nem veszi fel a tokent, a gép **új párosítókóddal** újra jelentkezik, és új jóváhagyás kell hozzá.

**Kézi út** (például ha az önregisztráció ki van kapcsolva), PowerShellből:

```powershell
ssh -t kevin@<ip> sudo install-worker.sh
```

Előbb a sudo-jelszót kéri, majd rejtett promptban a `wk_live_…` tokent. Ha a worker így települ, a `scrappy-register` magától leáll.

Hibakeresés a gépen:

```bash
# az első indítás naplója
journalctl -u scrappy-firstboot

# ha a fájl létezik, az első indítás lefutott
cat /var/lib/scrappy/firstboot.done

# a telepítő által használt config
sudo cat /var/log/installer/autoinstall-user-data

# önregisztráció: napló, állapot, API-cím
journalctl -u scrappy-register
sudo ls -l /var/lib/scrappy/        # registration.json, register.done / register.stopped
cat /etc/scrappy/register.env

# leltár (amit a worker a heartbeattel küld)
cat /opt/scrappy/host-info/inventory.json
```

A titok (`/var/lib/scrappy/claim_secret`) és a token csak root számára olvasható. A naplóba egyik sem kerül, és sikeres telepítés után a titok törlődik.

## Tesztelés Proxmox-VM-ben

Az ISO-t a Proxmox webes felületén töltsd fel: node → `local` → ISO Images → Upload.

| VM | Firmware | Lemezek |
|---|---|---|
| A | OVMF (UEFI), q35 | 32 GB virtio-scsi + 20 GB USB-ként bekötött lemez |
| B | SeaBIOS | 32 GB SATA |

Az A gép USB-lemezét a node shelljében kell hozzáadni. Először hozz létre egy képfájlt, majd kösd be USB-tárolóként (a `<vmid>` a VM azonosítója):

```bash
qemu-img create -f raw /var/lib/vz/images/<vmid>/usb-test.raw 20G
qm set <vmid> -args '-drive file=/var/lib/vz/images/<vmid>/usb-test.raw,if=none,format=raw,id=usb0 -device usb-storage,drive=usb0'
```

Ellenőrző lista: lásd az Outline-ban a „Scrappy worker – zero-touch telepítő” tervet.

> ⚠️ **Egy jóváhagyott teszt-gép éles jobokat vesz fel.** Az éles API ellen futó teszt-VM kérését **utasítsd el**, ne hagyd jóvá. Ha mégis jóvá kell hagyni, utána **azonnal** tiltsd le a teszt-workert az admin felületen, és állítsd le a VM-et. A teljes utat a lokális stack ellen (QEMU, `-devapi` ISO) érdemes tesztelni.
