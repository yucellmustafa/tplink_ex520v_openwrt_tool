# Donanım doğrulama planı

## 18–19 Ekim 2026 — NAND genişletme ve G menüsü testi

- `192.168.1.1` üzerinde salt okunur SSH incelemesi yapıldı.
- Çalışan model `tplink,ex520v`, sürüm `r32295+947-c25265953b`.
- MTD `ubi0`: `0x02100000`, 40 MiB; `ubi1`: `0x04900000`, 40 MiB.
- `ubi0` UBI içinde `uboot`, `kernel`, `rootfs` var; `rootfs_data` yok.
- `mount_root` günlüğü: `no usable overlay filesystem found, using tmpfs overlay`.
  `/rom` squashfs; `/` geçici `overlayfs:/tmp/root`. Yaklaşık 242 MiB görünen
  boş alan RAM'e ait. Bugünkü durum önceki kalıcı overlay ölçümünden farklı.
- wmemcmp referans imajlarının FIT/DTB ve initrd yükseltme kodu incelendi:
  kernel/rootfs 40 MiB `ubi0` içinde, overlay ayrı 407 MiB `ubi` içinde.
- Genişletme aralığı `0x04900000–0x1e000000`; stok slotu ve devamındaki stok
  veriler bu aralıkta kalıyor. `misc_ro` ve ilk bootloader alanları dışında.
- [x] Yeni envanter okuyucu fiziksel cihazda bölüm sınırlarını ve UBI volume'lerini okudu.
- [x] Küçük harita/geçici overlay üzerinde genişletme önkoşulları engellendi.
- [x] Devam eden çalışmada SSH/sysupgrade ile büyük kernel/DTS geçişi yapıldı; UART/TFTP kullanılmadı.
- [x] Eksik rootfs_data boş ubi0 alanında oluşturuldu; RAM ayarları kopyalandı.
- [x] Onarım sonrası reboot: 13.0 MiB toplam, 12.2 MiB boş UBIFS overlay doğrulandı.
- [x] Geçiş sonrası 407 MiB MTD ve `/dev/ubi2_0` kalıcı overlay açıldı.
- [x] Ağ/Wi-Fi ayarları ve SSH anahtarları yedekten geri yüklendi; dosya hash'leri eşleşti.
- [x] Sonraki reboot: 356.4 MiB toplam, 351.6 MiB boş alan ve kalıcılık işareti korundu.
- [x] misc_ro SHA256 değeri geçişten önceki tam yedekle aynı kaldı.
- [x] G menüsünün `bootstrap` ve `finalize` yolları aynı fiziksel cihazda araç üzerinden çalıştırıldı.
- [x] `finalize`, 407 MiB `ubi` bölümünü biçimlendirdi; sysupgrade sonrası büyük overlay ve ayar kalıcılığı doğrulandı.
- [x] U-Boot SHA256 `e31fca697a093e0baaca80b4d638f300672d23a8b05793438212a28935e1c992` iki aşama ve son reboot boyunca değişmedi.
- [ ] Fiziksel güç döngüsü ve daha sonraki firmware sysupgrade ayrıca test edilmeli.

İlk salt okunur incelemede NAND'a yazılmadı. Sonraki SSH çalışmasında eksik
overlay onarıldı ve firmware/kernel geçişi yapıldı. Tam NAND/ayar yedeği:
`Backups/20261019-001638-openwrt-recovery-070951dc/` (11 MTD, boyut ve SHA256
doğrulaması). Son sistem `OpenWrt SNAPSHOT r0-6c12b87`, kernel `6.18.44`.
19 Ekim 2026 tarihli son G testi yalnız aracın menü/PowerShell/shell çağrı
zinciriyle yürütüldü; cihazda elle flash/UBI yazma komutu kullanılmadı. Son boot
ID `9ed704f9-1ae3-4d1a-bc18-86388efa6817`; önceki boot'tan yazılan kalıcılık
işareti korundu. Aynı cihazın tam stok yedeğiyle geri dönüş daha sonra ayrıca
doğrulandı.

## 19 Ekim 2026 — genişletilmiş NAND'dan tam stok yedeğine dönüş

- Kaynak durum: `192.168.1.1`, `OpenWrt SNAPSHOT r0-6c12b87`, kernel `6.18.44`,
  altı bölümlü genişletilmiş harita; `ubi0` 40 MiB ve `ubi` 407 MiB.
- Kullanılan yedek: `Backups/20261017-035630-3e9df44cd7ef2e48/`, stok sistemden
  alınmış 11 bölüm ve SHA256 manifesti.
- [x] Canlı `misc_ro` SHA256
  `61c5fb454ce3c4352b8fcdeda2f7829d16a5f42c17beb2c007d5b303481b4906`
  yedekle eşleşti.
- [x] RAM-pivot içinde stok veri alanları ve `ubi1` önce, birincil `ubi0` en son
  yazıldı; yedi üyenin tamamı yazma sonrası NAND'dan SHA256 ile doğrulandı.
- [x] `tp_boot_idx` ve `ex520v_trial` temizlendi; cihaz stok `ubi0` ile açıldı.
- [x] Açılış sonrası stok bölüm haritası (`ubi0`, `ubi1`, `bflag`,
  `misc_rw_bak`, `misc_isp`, `runtime_data`, `container`) doğrulandı.
- [x] `ubi0`, `ubi1` ve `bflag` yedekle birebir kaldı. Stok ilk açılışta
  `misc_rw_bak` içeriğini güncellediğinden değişebilir alanlar doğru boyut ve
  tam okunabilirlikle doğrulandı.
- [x] Araç canlı sistemi `Stok`, taşıma profilini TCP/2222 `Stock` ve komut
  satırını `ubi.mtd=ubi0` olarak algıladı; işlem kaydı `complete` oldu.
- [x] Kurtarma UART yazma komutlarıyla değil, aracın
  `Start-Ex520vStockRestoreFromBackup`/SSH/RAM-pivot akışıyla tamamlandı.

Bu depoda yapılan otomatik testler gerçek NAND'a yazmaz. Aşağıdaki maddeler,
yayın adayı gerçek bir EX520v üzerinde denenmeden “doğrulandı” olarak
işaretlenmemelidir.

## Test cihazı kaydı

- Cihaz modeli ve donanım revizyonu:
- Stok firmware: `EX520v_260514`
- Root aracı sürümü/commit'i:
- OpenWrt release etiketi ve iki SHA256 değeri:
- Windows sürümü ve OpenSSH sürümü:
- Test tarihi / uygulayan kişi:

## Zorunlu senaryolar

- [x] Windows root başlatıcısı web oturumunu tamamlıyor.
- [x] TCP/2222 bağlantısı cihazın özel anahtarı ve özel `known_hosts` dosyasıyla UID 0 dönüyor.
- [x] Tüm MTD bölümleri doğru boyutta alınıyor; `misc_ro`, device tree ve environment yedekte.
- [ ] Yedek SHA256 manifesti ikinci bir bilgisayarda doğrulanıyor.
- [x] Stok `ubi1` çalışırken `stock-install-trial.sh --check` yazmadan geçiyor.
- [x] RAM deneme yazması sonrası bütün static volume CRC geri okumaları eşleşiyor.
- [x] Yeniden açılış gerçekten initramfs/RAM; `/tmp/ex520v-trial=armed` ve `tp_boot_idx=1`.
- [ ] Güç kesilip açıldığında cihaz stok `ubi1` sistemine dönüyor.
- [x] RAM denemeden flash yazımında `sysupgrade -T` geçiyor ve volume SHA256 geri okumaları eşleşiyor.
- [x] Sonraki açılış flash deneme olarak algılanıyor; overlay `ubifs`.
- [ ] Deneme bayrağı aktifken güç döngüsü stoka dönüyor.
- [x] Kalıcılaştırma sonrası `tp_boot_idx` ve `ex520v_trial` silinmiş.
- [ ] Kalıcı OpenWrt yeniden başlatma ve güç döngüsünden sonra açılıyor.
- [ ] Slot tabanlı stok dönüşten sonra stok firmware açılıyor.
- [ ] Yanlış model, yanlış slot, bozuk imaj ve kesilen SSH işlemlerinde yazma başlamıyor.
- [ ] Yazma sırasında kontrollü hata enjeksiyonunda başarı mesajı gösterilmiyor.

## İşlev kontrolü

- [ ] LAN1/LAN2/LAN3 ve WAN
- [ ] 2.4 GHz ve 5 GHz Wi-Fi; fabrika kalibrasyonu/MAC adresleri
- [ ] Ayarların yeniden başlatmada korunması
- [ ] LED, düğmeler ve USB (referans projede v1.0.0 itibarıyla doğrulanmamış)
- [ ] UART kurtarma erişimi ve 115200 8N1 seri çıktı

FXS/telefon portu desteklenmez; başarılı test beklenmez.

## 17 Ekim 2026 — eski firmware çekirdek root testi

- Cihaz: `EX520v`, donanım `EX520v_V1`
- Firmware: `EX520v-v1.0_250522`
- İstemci: Windows 10 build 19044, OpenSSH 9.5p2
- Root aracı: `root-agent-legacy-1`, doğrudan paketlenmiş Python motoru
- [x] Panelden model, donanım ve firmware parmak izi okundu.
- [x] Özgün Lifemote durumu kaldırma için yerelde ve cihazda kaydedildi.
- [x] UID 0 Telnet, anahtar tabanlı SSH ve token doğrulamalı root API açıldı.
- [x] TCP/2222 SSH üzerinden `/proc/self/status` UID alanları `0 0 0 0` olarak
  doğrulandı.
- [x] LXC pre-start kancası tek satır olarak yazıldı ve kalıcı Lifemote URL'si
  cihazdan geri okundu.
- [x] TCP/8443 dışarıdan kapalı/filtreli doğrulandı.
- [x] Eski profilde sabit adresli HTTP daemon bellek yamaları çalıştırılmadı ve
  `ex520-web-root-init` cihaza kurulmadı.
- [ ] Yeniden başlatma/güç döngüsü sonrası root kalıcılığı ayrıca test edilmedi.
- [x] Tam NAND yedeği `20261017-025427-36b79277cde66900` dizinine alındı;
  11 MTD bölümü, environment, device tree ve SHA256 manifesti doğrulandı.
- [x] OpenWrt RAM ve flash denemeleri `ubi0` üzerinde tamamlandı; korunmuş stok
  sistem `ubi1` üzerinde bırakıldı.
- [x] Flash açılışında `/rom=squashfs`, `/overlay=/dev/ubi0_3 (ubifs)` ve
  `ubi.mtd=ubi0` doğrulandı.
- [x] Kalıcılaştırma sonrası yazılımsal yeniden başlatma yapıldı;
  cihaz kalıcı OpenWrt olarak geri geldi ve deneme işaretleri boş kaldı.
- [ ] Fiziksel güç kesme/açma ve slot tabanlı stok dönüşü ayrıca test edilmedi.

## 17 Ekim 2026 — tam eski firmware OpenWrt kurulumu

- Cihaz: `EX520v`, donanım `EX520v_V1`, stok firmware `EX520v-v1.0_250522`
- OpenWrt: `OpenWrt 25.12-SNAPSHOT r32295+947-c25265953b`
- Initramfs SHA256: `e448e0209d21c1fb2dffc862ebb899e0043d73f14895e597da8c07420eea9b6d`
- Sysupgrade SHA256: `d97e904fcba00855aaa96b0ada04e1a85f48b6a1faefd4757ef731aebd5b847b`
- Son yönetim adresi: `192.168.1.1`
- Son durum: kalıcı OpenWrt; `ubi0` aktif, stok `ubi1` korunmuş

