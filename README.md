# TP-Link EX520v OpenWrt Tool

TP-Link EX520v için stok sistem yedeği alma, OpenWrt kurma, depolama alanını
genişletme ve stok firmware'e dönme işlemlerini yöneten Windows aracıdır.

> **Uyarı:** Araç NAND flash'a yazabilir. Elektrik kesintisi, yanlış dosya veya
> işlemin yarıda kesilmesi cihazın açılmamasına neden olabilir. Başlamadan önce
> tam yedek alın, cihazı Ethernet ile bağlayın ve sabit güç kullanın.

## Özellikler

- Stok firmware'de root SSH erişimini açma ve doğrulama
- Tüm MTD bölümlerini SHA256 doğrulamasıyla yedekleme
- OpenWrt RAM denemesi, flash kurulumu ve kalıcılaştırma
- OpenWrt depolama alanını tek menü adımıyla genişletme
- Normal veya genişletilmiş düzenden doğrulanmış yedekle stok sisteme dönme
- Her kritik adımdan önce cihaz, slot, imaj ve bölüm haritası kontrolü
- Yarım kalan yeniden başlatma ve doğrulama aşamalarını güvenli biçimde sürdürme

## Desteklenen ortam

| Bileşen | Destek |
| --- | --- |
| Cihaz | Yalnızca TP-Link EX520v |
| Stok firmware | `EX520v_260514`, `EX520v-v1.0_250522`, `EX520v-v1.0_250120` |
| OpenWrt | `wmemcmp/ex520v` commit `4c42b65bb00fafde863610fd0e86fdb51ba074cd` |
| OpenWrt sürümü | SNAPSHOT `r0-6c12b87`, kernel 6.18 |
| Bilgisayar | Windows 10/11 x64, PowerShell 5.1, OpenSSH Client ve `tar.exe` |
| Telefon/FXS | Desteklenmez |

Başka model, stok firmware veya OpenWrt imajı kabul edilmez. Donanım üzerinde
uygulanan testlerin kaydı [HARDWARE_TESTS.md](HARDWARE_TESTS.md) dosyasındadır.

## Başlamadan önce

1. Bilgisayarı cihazın LAN portuna Ethernet kablosuyla bağlayın.
2. Cihazı ve bilgisayarı işlem boyunca kapatmayın.
3. Önce menü 3 ile tam stok yedeği alın.
4. Kurulum tamamlanana kadar OpenWrt root parolasını değiştirmeyin.
5. Uyarı ekranlarını okuyun; yalnızca ne yaptığınızdan eminseniz devam edin.

Onay sorularında yalnızca `e` veya `h` kabul edilir. Boş Enter geçerli değildir
ve soru yeniden gösterilir.

## Çalıştırma

Release paketindeki `ex520v-tool.exe` dosyasını çalıştırın veya kaynak koddan:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ex520v-tool.ps1
```

Cihaz farklı bir IP adresindeyse:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ex520v-tool.ps1 -DeviceIp 192.168.0.1
```

Varsayılan cihaz adresi `192.168.1.1`'dir.

## Önerilen kurulum sırası

1. **Bağlantıyı kontrol edin:** Menü 1
2. **Root SSH erişimini açın:** Menü 2
3. **Tam stok yedeği alın:** Menü 3
4. **OpenWrt RAM denemesini başlatın:** Menü 4
5. **OpenWrt'yi flash'a kurun:** Menü 5
6. **Kurulumu kalıcı yapın:** Menü 6
7. İsterseniz **depolama alanını genişletin:** Menü G

Araç her yeniden başlatmadan sonra beklenen sistemin gerçekten açıldığını
denetler. SSH bağlantısının kesilmesi tek başına başarı sayılmaz.

## Menü

| Seçim | İşlem |
| --- | --- |
| 1 | Cihaz bağlantısını kontrol et |
| 2 | Root SSH erişimi aç / kontrol et |
| 3 | Stok firmware yedeği al |
| 4 | OpenWrt RAM deneme kurulumu |
| 5 | OpenWrt flash kurulumu |
| 6 | OpenWrt kurulumunu kalıcı yap |
| 7 | Stok firmware'e geri dön |
| 8 | Dosyaları ve gereksinimleri kontrol et |
| 9 | İşlem kayıtları ve cihaz bilgileri |
| G | OpenWrt depolama alanını genişlet |
| A | Cihaz IP adresini değiştir |
| 0 | Çıkış |

## Firmware dosyaları

Araç gerekli firmware paketini şu sabit adresten indirebilir:

<https://github.com/yucellmustafa/tplink_ex520v_openwrt_tool/releases/download/OpenWrt/tplink_ex520v_openwrt.zip>

İnternet olmadan kullanmak için ZIP dosyasını `files/` klasörüne koyabilir veya
içeriğini doğrudan bu klasöre açabilirsiniz. Geçerli yerel dosyalar bulunduğunda
yeniden indirme yapılmaz.

Kabul edilen imajların SHA256 değerleri:

```text
initramfs: 969955078a93f27a7f70a3e71a76c111199f7df53434d6d2e5158d749535f5e4
sysupgrade: 3f066005e89afc8fae214e874ea3b4e40d9ad0639daff494b4ff258f7a1bbe0b
```

Araç hash değerlerinin yanında FIT başlığını, sysupgrade arşiv yapısını ve
EX520v cihaz metadata'sını da doğrular. Farklı sürümlere ait dosyaları
karıştırmayın veya dosya adlarını değiştirmeyin.

## Yedekleme ve stok sisteme dönüş

Yedekler `Backups/YYYYMMDD-HHMMSS-cihazkimliği/` altında saklanır. Her bölümün
boyutu ve SHA256 değeri doğrulanır. Yedekler yalnız alındıkları cihazla eşleşirse
geri yüklenebilir.

`misc_ro` bölümü cihaza özel MAC adresleri ve Wi-Fi kalibrasyon verileri içerir.
Yedek klasörünü özel veri kabul edin ve çevrimdışı ikinci bir konumda saklayın.

Menü 7 iki durumu otomatik ayırır:

- Normal düzende korunmuş stok slotu doğrulanır ve yeniden seçilir.
- Genişletilmiş düzende aynı cihaza ait tam yedek kullanılarak stok bölüm
  haritası geri yüklenir.

Genişletilmiş düzenden stok sisteme dönüş 10 dakikadan uzun sürebilir. Yazma,
geri okuma, yeniden açılış ve son doğrulamalar tamamlanana kadar uygulamayı
kapatmayın; Ethernet bağlantısını veya cihazın gücünü kesmeyin. İşlem sonrası
OpenWrt ayarları, paketleri ve genişletilmiş depolama alanı silinir.

## Depolama alanını genişletme (G)

G seçeneği kalıcı OpenWrt kurulumundaki küçük depolama alanını genişletir. İşlem
başlamadan önce uyumlu firmware, tam cihaz yedeği, bölüm haritası, U-Boot,
kalibrasyon verisi ve çalışan overlay kontrol edilir.

Bu işlem stok firmware'in kullandığı ikincil alanları OpenWrt verisine ayırır.
Ham bölüm yaklaşık 407 MiB'dir; UBI/UBIFS metadata'sı ve bozuk blok rezervleri
nedeniyle kullanılabilir alan daha az olur. Test edilen cihazda yaklaşık
356 MiB toplam alan görülmüştür, ancak bu değer her NAND için garanti edilmez.

Genişletmeden sonra stok sisteme dönüş yalnız aynı cihaza ait doğrulanmış tam
yedekle yapılır. Menü 7 gerekli bölüm haritasını ve stok verilerini geri yükler.

## Sık karşılaşılan sorunlar

- **Root SSH aktif değil:** Menü 2'yi çalıştırın. Desteklenmeyen stok firmware'de
  root işlemi başlatılmaz.
- **İmajlar hazır değil:** Menü 8 ile dosyaları denetleyin ve gerekirse firmware
  ZIP paketini indirin.
- **SHA256 veya metadata hatası:** Dosyaları yeniden indirin; farklı firmware
  sürümlerini birlikte kullanmayın.
- **Yeniden açılış uzun sürüyor:** İlk açılış ve genişletilmiş stok dönüşü zaman
  alabilir. Araç hata vermeden güç döngüsünü tekrarlamayın.
- **SSH host key değişti:** Aynı IP'de başka cihaz veya sıfırlanmış sistem
  bulunabilir. Cihaz kimliğini doğrulamadan kayıtları silmeyin.
- **OpenWrt root parolası değiştirildi:** Araç otomatik SSH bağlantısı kuramaz.
  Kurulum aşamalarını parola değişikliğinden önce tamamlayın.

Cihaz açılmıyorsa veya hiçbir SSH bağlantısı kurulamıyorsa UART kurtarma
gerekebilir. UART günlük kullanım ya da normal kurulum akışının parçası değildir.

## Test ve paket oluşturma

Testleri çalıştırmak için:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
py -3 -m unittest discover -s tests -p "test_*.py" -v
```

EXE ve Windows ZIP paketi oluşturmak için önce PS2EXE'yi kurun:

```powershell
Install-Module ps2exe -Scope CurrentUser
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Version 0.7.8
```

Build betiği testleri çalıştırır, kök dizindeki `icon.png` dosyasını uygulama
simgesi olarak kullanır ve çıktıları `release/` klasörüne yazar. Firmware,
yedekler, günlükler ve kullanıcı kimlik bilgileri pakete eklenmez.

## Kaynaklar ve lisans

- OpenWrt firmware: [wmemcmp/ex520v](https://github.com/wmemcmp/ex520v)
- Stok root bileşeni: [emrycl/EX520v-tek-tus-root-araci](https://github.com/emrycl/EX520v-tek-tus-root-araci)
- Windows araç yaklaşımı: [yucellmustafa/tplink_ex20v_openwrt_tool](https://github.com/yucellmustafa/tplink_ex20v_openwrt_tool)

Proje GPL-3.0-or-later lisansı altında dağıtılır. Ayrıntılar için
[LICENSE](LICENSE) ve [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) dosyalarına bakın.
