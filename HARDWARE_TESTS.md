# Donanım doğrulama planı

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

