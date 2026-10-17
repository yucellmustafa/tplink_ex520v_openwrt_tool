# TP-Link EX520v OpenWrt Tool

Windows 10/11 x64 üzerinde TP-Link EX520v (Türk Telekom AX3000) için stok
yedekleme, güvenli OpenWrt deneme kurulumu, flash kurulumu, kalıcılaştırma ve
korunmuş stok slota dönüş akışını yöneten Türkçe terminal aracıdır.

> **Deneysel ve riskli:** Bu yazılım NAND flash'a yazar. Elektrik kesintisi,
> yanlış/bozuk imaj veya beklenmeyen donanım farkı cihazı açılmaz duruma
> getirebilir ve UART kurtarma gerektirebilir. Yalnız sahibi olduğunuz veya
> yönetmeye açıkça yetkili olduğunuz cihazlarda kullanın.

Temel OpenWrt akışı referans projenin 26 Eylül 2026 tarihli cihaz testine
dayanır. Entegre root motoru 17 Ekim 2026'da Windows üzerinde fiziksel
`EX520v_V1 / EX520v-v1.0_250522` cihazda UID 0 SSH/Telnet/API düzeyinde
doğrulandı. Aynı cihazda tam NAND yedeği, RAM denemesi, flash denemesi,
kalıcılaştırma ve yeniden başlatma doğrulaması da tamamlandı. Ayrıntılı
yayın kontrol listesi [HARDWARE_TESTS.md](HARDWARE_TESTS.md) dosyasındadır.

## Destek kapsamı

- Cihaz: yalnız `TP-Link EX520v`
- Root aracı stok firmware'i: `EX520v_260514` (tam profil) ve
  `EX520v-v1.0_250522` (güvenli çekirdek root profili)
- OpenWrt imajları: `yibudak/ex520v-openwrt` projesinin EX520v release imajları
- OpenWrt tabanı: referans v1.0.0 sürümünde OpenWrt 25.12 / kernel 6.12
- Windows: Windows 10/11 x64, PowerShell 5.1, Windows OpenSSH Client ve `tar.exe`
- Telefon/FXS portu: **desteklenmez**

Root aracı Python 3, Chrome/Chromium ve OpenSSH gereksinimlerini kendi Windows
başlatıcısıyla denetler; gerekirse `winget` ve UAC kullanır. Ana OpenWrt aracı
Python, Git, WSL veya Linux terminali gerektirmez.

## Mimari karar

PowerShell 5.1 seçildi: Windows 10/11'de yerleşik, OpenSSH ve dosya/hash API'leri
için yeterli ve tek EXE başlatıcısına paketlenebilir. Windows katmanı cihazın
canlı durumunu tekrar tekrar belirler ve aşama sırasını uygular. NAND yazma
komutları yeniden icat edilmemiştir; donanımda denenmiş referans shell
betikleri cihaza aktarılıp kendi model, slot, UBI, CRC/SHA ve boot environment
kontrolleriyle çalıştırılır.

Yerel `state/last-operation.json` yalnız bilgi amaçlıdır. Program yeniden
açıldığında hiçbir aşama bu kayda güvenilerek başarılı sayılmaz.

## Güvenli kurulum sırası

1. Cihazı Ethernet kablosuyla bağlayın.
2. Menü 2 ile root aracını çalıştırın. Araç model ve firmware profilini kendi
   içinde doğrular. `EX520v-v1.0_250522` sürümünde UID 0 SSH/Telnet/API kurulur;
   yeni firmware'e özgü web-panel bellek yamaları güvenlik için atlanır.
3. Ana araç TCP/2222 üzerinde cihaza özel anahtar ve `known_hosts` dosyasıyla
   gerçek UID 0 erişimini doğrular.
4. Menü 3 ile bütün MTD bölümlerini, `/proc/mtd`, U-Boot environment ve canlı
   device tree'yi yedekleyin. Boyutlar ve SHA256 doğrulanmadan ilerlenmez.
5. Menü 4, stok sistemin `ubi1` slotunda çalıştığını doğrular; initramfs
   kernelini ve sysupgrade içindeki squashfs root'u pasif `ubi0` slotuna
   `uboot/kernel/rootfs` volume düzeniyle yazar. `ubicrc32` geri okuması ve
   `ex520v_trial`/`tp_boot_idx` sırası referans betikte korunur.
6. Yeniden açılışın gerçekten RAM/initramfs denemesi olduğu doğrulanır.
7. Menü 5, yalnız bu ortamda `sysupgrade -T` sonrasında `ubi0` volume'lerini
   flash OpenWrt düzenine çevirir ve geri okur.
8. Flash deneme açılışı doğrulandıktan sonra menü 6 ayrı yazılı onayla kurulumu
   kalıcı yapar. Stok firmware `ubi1` slotunda kalır.

Her kritik aşama öncesinde canlı model, sistem, slot ve geri dönüş durumu
yeniden okunur. Bağlantının kesilmesi başarı kabul edilmez; beklenen sistemle
yeniden SSH bağlantısı kurulmadan başarı gösterilmez.

## Çalıştırma

Kaynak koddan:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ex520v-tool.ps1
```

Farklı cihaz adresi:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ex520v-tool.ps1 -DeviceIp 192.168.0.1
```

Release paketinde `ex520v-tool.exe` dosyasına çift tıklayın. Aracı internetten
indirdiyseniz ZIP ve EXE kaynağını ayrıca doğrulayın.

## Firmware dosyaları

Menü 8 son kararlı GitHub Release sürümünü indirebilir. İki imaj ve
`SHA256SUMS.ex520v` aynı release dizinine konur. Araç:

- iki SHA256 değerini,
- initramfs FIT başlığını,
- sysupgrade tar yapısını,
- `kernel`, `root`, `CONTROL` üyelerini,
- `BOARD=tplink_ex520v` (veya `tplink,ex520v`) cihaz metadata'sını

doğrular. Dosya adı tek başına güven kanıtı değildir. Elle seçilen dosyalarda
da checksum manifesti zorunludur. Farklı release dosyalarını karıştırmayın.
GitHub CLI kuruluysa ayrıca yayın attestations bilgisini bağımsız olarak
doğrulayabilirsiniz:

```powershell
gh attestation verify .\openwrt-*-tplink_ex520v-*.bin -R yibudak/ex520v-openwrt
```

## Root SSH ve anahtarlar

Entegre bileşen [emrycl/EX520v-tek-tus-root-araci](https://github.com/emrycl/EX520v-tek-tus-root-araci)
projesidir. Stok erişim TCP/2222 üzerinde, cihaza özel RSA anahtarıyla UID 0
olarak açılır. Araç standart port 22 veya sabit parola varsaymaz.

Kimlik bilgileri `%USERPROFILE%\.local\state\ex520-root\devices\...` altında
root aracı tarafından tutulur. Özel anahtar, parola ve API tokenı günlüklere
yazılmaz. Stok SSH'de `StrictHostKeyChecking=yes`; OpenWrt ilk bağlantısında
cihaza özel dosyada `accept-new`, sonraki bağlantılarda anahtar değişikliği
reddedilir. Sistem genelindeki `known_hosts` değiştirilmez.

Root erişimini açtıktan sonra stok firmware'i fabrika ayarına döndürmek root
erişimini ve cihaz anahtarını geçersiz kılabilir.

## Stok yedekleme

Yedekler `Backups/YYYYMMDD-HHMMSS-cihazkimliği/` altında tutulur. Yedekleme
salt okunurdur; `/dev/mtd*` verisini `cat` ile okur ve hiçbir flash yazma aracı
çağırmaz. Her bölümün boyutu `/proc/mtd` ile eşleşmeli, device tree en az 1 KiB
olmalı ve bütün `.bin`/`.dtb` dosyaları SHA256 manifestinden geçmelidir.

`misc_ro` Wi-Fi kalibrasyonu ve cihaza özgü MAC bilgileri içerir. Yedekleri
özel veri kabul edin ve güvenli, çevrimdışı ikinci bir konumda saklayın.

Bu sürüm yedek dosyalarını flash'a geri yüklemez. Doğrulanmış tam EX520v geri
yükleme prosedürü olmadan böyle bir özellik güvenli değildir.

## Stok firmware'e dönüş

Menü 7, yalnız çalışan OpenWrt üzerinden `ubi1` içindeki `uboot`, `kernel` ve
`rootfs` volume'lerinin var ve dolu olduğunu kontrol eder. Ardından deneme
bayrağını siler, `tp_boot_idx=1` yazar ve geri okur. Bu, yedekten geri yükleme
değil, korunmuş stok slotunu seçme işlemidir.

SSH yoksa, `ubi1` doğrulanamıyorsa veya cihaz açılmıyorsa araç durur. Bu durumda
UART (3.3 V, 115200 8N1; VCC bağlamayın) üzerinden kurtarma gerekebilir.

## Kurulum sonrası

Referans imajın ilk açılış değerleri:

- Wi-Fi adı: `OpenWrt-EX520v`
- Wi-Fi parolası: `openwrt-ex520v`
- LuCI: `http://192.168.1.1`
- root parolası: boş

İlk iş Wi-Fi adını/parolasını ve root parolasını değiştirin. Kalıcılaştırma
bitene kadar aracın SSH doğrulamasını tamamlayabilmesi için root parolasını
değiştirmeyin; aksi durumda Windows OpenSSH ile otomatik bağlantı kurulamaz.

## Sık karşılaşılan hatalar

- **Web var, root SSH yok:** Menü 2'yi çalıştırın; desteklenen stok firmware
  dışında root işlemi yapılmaz.
- **SSH anahtarı bulunamadı:** Root aracını aynı Windows kullanıcı hesabında
  çalıştırın; anahtarları elle başka cihazdan kopyalamayın.
- **Host key değişti:** IP'de başka cihaz veya fabrika sıfırlama olabilir.
  Kimliği doğrulamadan `known_hosts` kaydını silmeyin.
- **Stok ubi1'den çalışmıyor:** RAM kurulumunu zorlamayın. Mevcut slot durumunu
  ve önceki işlemleri inceleyin.
- **SHA256/metadata hatası:** Dosyayı yeniden indirin; farklı sürümleri
  karıştırmayın.
- **Yeniden açılış doğrulanmıyor:** Beş dakikalık ilk açılışı bekleyin. Güç
  döngüsünü körlemesine tekrarlamayın; gerekirse UART logunu inceleyin.
- **OpenWrt parolası değiştirildi:** Araç etkileşimsiz SSH kuramaz. Kurulum
  aşamalarını parola değişikliğinden önce tamamlayın veya yetkili anahtar
  erişimini elle yapılandırın.

## Testler

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

Testler yanlış model/firmware, eksik anahtar, SHA256 uyuşmazlığı, yarım yedek,
yanlış slot/sıra, fallback ve boot environment hataları, SSH kesilmesi, UBI
geri okuma hatası, beklenmeyen reboot ve UBI CRC32 vektörünü kapsar. Bunlar
mock/saf mantık testleridir; gerçek NAND testi değildir.

## EXE ve Windows ZIP paketi

Bir kez PS2EXE kurun:

```powershell
Install-Module ps2exe -Scope CurrentUser
```

Sonra:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Version 0.3.0
```

Betik önce testleri çalıştırır, x64 `ex520v-tool.exe` üretir, gerekli
`modules/`, `install/` ve GPL uyumlu `root-tool/` bileşenlerini paketler,
Windows ZIP'i ve `.sha256` dosyasını `release/` altında oluşturur. Firmware,
yedek, günlük ve kullanıcı kimlik bilgileri pakete alınmaz.

## Kaynaklar ve lisans

- Windows yaklaşımı: [yucellmustafa/tplink_ex20v_openwrt_tool](https://github.com/yucellmustafa/tplink_ex20v_openwrt_tool)
- EX520v OpenWrt ve donanımda denenmiş kurulum betikleri: [yibudak/ex520v-openwrt](https://github.com/yibudak/ex520v-openwrt)
- Stok root bileşeni: [emrycl/EX520v-tek-tus-root-araci](https://github.com/emrycl/EX520v-tek-tus-root-araci)

Birleşik proje, dahil edilen GPL-3.0-or-later root bileşeni nedeniyle
GPL-3.0-or-later altında dağıtılır. Ayrıntılar [LICENSE](LICENSE) ve
[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) dosyalarındadır.
