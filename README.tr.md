<p align="center">
  <img src="Resources/AppIcon/Vitrin.png" width="128" alt="Vitrin simgesi">
</p>

<h1 align="center">Vitrin</h1>

<p align="center">
  macOS için ücretsiz ve açık kaynak pencere değiştirici — Windows ve Linux'taki gibi Alt+Tab.
  <br>
  <a href="README.md">English</a> ·
  <a href="https://github.com/ozanhakantunca/vitrin/releases/latest">İndir</a>
</p>

---

macOS'taki ⌘Tab uygulamalar arasında geçiş yapar. Vitrin ise **pencereler** arasında geçiş yapar:
tüm masaüstlerindeki her pencereyi canlı önizlemesiyle gösterir. Her şey ücretsizdir; ücretli bir
sürümü yoktur.

## Özellikler

- **Tüm pencereler** — diğer masaüstlerindeki (Space) pencereler, küçültülmüş pencereler ve gizli
  uygulamalar dahil.
- **Canlı küçük resimler** ya da sade uygulama simgesi veya başlık listesi görünümü.
- **Görev Görünümü** — Windows'taki Win+Tab gibi tüm pencerelerin tam ekran görünümü; alttaki
  masaüstü şeridiyle masaüstleri (Space) arasında geçiş.
- **Yazarak arama** — uygulama adlarında ve pencere başlıklarında bulanık eşleşme, Türkçe karakter
  desteğiyle.
- **Pencereleri switcher'dan yönetme**: kapatma, küçültme, tam ekran, gizleme, uygulamadan çıkma.
- **Sınırsız kısayol**; her birinin kendi filtresi (tüm pencereler, geçerli uygulama, geçerli
  masaüstü…) ve görünümü olabilir.
- **İsteğe bağlı ⌘Tab devralma**; Vitrin kapanınca macOS'un ⌘Tab'ı otomatik geri gelir.
- **Uygulama istisnaları** — sanal makineler ve uzak masaüstü uygulamaları Alt+Tab'ı kendileri
  almaya devam eder.
- **Düz metin ayar dosyası**: `~/.config/vitrin/config.json`, değişiklikler anında uygulanır;
  dotfiles ile uyumlu.
- **Komut satırı aracı**: `vitrin list`, `vitrin focus`, `vitrin show`.
- İsteğe bağlı üç parmakla trackpad kaydırma, güncelleme bildirimleri, Türkçe ve İngilizce arayüz.

macOS 13 Ventura veya daha yenisi gerekir; Apple silicon ve Intel Mac'lerde çalışır.

## Kurulum

### İndirerek (DMG)

1. [Son sürümden](https://github.com/ozanhakantunca/vitrin/releases/latest) `Vitrin-x.y.z.dmg`
   dosyasını indirin ve **Vitrin**'i **Uygulamalar** klasörüne sürükleyin.
2. Vitrin Apple tarafından onaylanmadığı (notarize edilmediği) için ilk açılış engellenir. Uygulamayı
   bir kez açın, ardından **Sistem Ayarları → Gizlilik ve Güvenlik** bölümünde **Yine de Aç**'a
   tıklayın. Ya da şu komutu çalıştırın:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Vitrin.app
   ```

### Kaynaktan derleyerek

Xcode Komut Satırı Araçları gerekir (`xcode-select --install`).

```sh
git clone https://github.com/ozanhakantunca/vitrin
cd vitrin
./scripts/create-signing-cert.sh   # bir kez: yerel imza kimliği; izinler yeniden derlemede korunur
./scripts/install.sh --with-cli    # derler, /Applications'a kurar ve `vitrin` komutunu bağlar
```

### İzinler

Vitrin ilk açılışta şu izinleri ister:

- **Erişilebilirlik** (gerekli) — pencereleri listelemek, öne getirmek ve yönetmek için.
- **Ekran Kaydı** (isteğe bağlı) — küçük resimler için. İzin verilmezse uygulama simgeleri gösterilir.

Vitrin varsayılan olarak girişte açılır; **Ayarlar → Genel → Girişte başlat** ile kapatabilirsiniz.

## Kullanım

| Tuşlar | İşlev |
|---|---|
| ⌥Tab | Switcher'ı aç / sonraki pencere. ⌥'yi bırakınca geçer. |
| ⌥⇧Tab | Önceki pencere |
| ⌥ + Tab'ın üstündeki tuş | Yalnızca geçerli uygulamanın pencereleri |
| Ok tuşları | Seçimi taşı |
| Return | Seçili pencereye geç |
| Esc | İptal |
| Harf yazmak | Ara |
| ⌃ veya ⌘ + W / M / F / H / Q | Kapat / küçült / tam ekran / uygulamayı gizle / uygulamadan çık |
| Delete (⌦) | Seçili pencereyi kapat |

⌥Tab'a hızlıca basıp bırakırsanız panel hiç açılmadan bir önceki pencereye geçilir.

**Görev Görünümü** varsayılan olarak kapalıdır. **Ayarlar → Kısayollar** bölümünden açabilirsiniz:
⌘Tab ile açılır ve bir pencere seçene kadar açık kalır. Alttaki şerit masaüstlerinizi gösterir: son
satırdan ↓ ile (ya da tıklayarak) şeride inin, ←/→ ile seçin ve Return ile geçin. Geçince o masaüstünde
en son kullanılan pencere öne gelir; boş bir masaüstüne doğrudan geçilir.

### Windows'tan gelenler için

macOS modundaki bir Windows klavyesinde **Alt, ⌥** ve **Windows tuşu, ⌘** olarak çalışır. Yani:

- **Alt+Tab** alıştığınız gibi çalışır; Alt basılıyken **Ctrl+W** seçili pencereyi kapatır.
- Görev Görünümü açıldıktan sonra **Win+Tab** onu açar; masaüstü şeridiyle masaüstü değiştirebilirsiniz.

Karabiner-Elements gibi bir tuş eşleme aracında Win+Tab (⌘Tab) için ayrı bir kural varsa kaldırın;
o kural tuşu Vitrin'den önce yakalar.

## Ayarlar

Tüm ayarlar Ayarlar penceresinde bulunur (menü çubuğu simgesi → Ayarlar). Aynı ayarlar
`~/.config/vitrin/config.json` dosyasında da durur ve bu dosyadaki değişiklikler anında uygulanır.
Örneğin geçerli uygulamanın pencereleri için bir ⌃Tab kısayolu:

```json
{
  "schemaVersion": 1,
  "profiles": [{
    "id": "my-windows", "name": "Pencerelerim", "enabled": true,
    "trigger": "control+tab", "filters": {"apps": "activeApp"},
    "style": "thumbnails", "size": "auto", "onModifierRelease": "focusSelection"
  }]
}
```

`profiles` listesi yerleşik kısayolların yerini alır; korumak istediğiniz tüm kısayolları listeye
ekleyin.

## Komut satırı

```sh
vitrin list            # pencereler, en son kullanılandan başlayarak
vitrin focus <id>      # bir pencereyi kimliğiyle öne getir
vitrin show [profil]   # switcher'ı aç
```

## Sorun giderme

- **Anahtar açık olduğu hâlde Vitrin Erişilebilirlik izni istemeye devam ediyor.** İzin, imzası farklı
  eski bir derlemeye ait. Kaydı sıfırlayın, Vitrin'i yeniden başlatın ve anahtarı tekrar açın:
  `tccutil reset Accessibility io.github.ozanhakantunca.vitrin`
- **Bir kısayol çalışmıyor.** Aynı kısayolu başka bir uygulamanın (başka bir pencere değiştirici ya da
  tuş eşleme aracı) kullanmadığından emin olun.

## Kaldırma

Vitrin'den çıkın ve Uygulamalar klasöründen silin. Ya da kaynak klasöründe
`./scripts/uninstall.sh` komutunu çalıştırın (`--purge-config`, `~/.config/vitrin` klasörünü de siler).

## AltTab ile karşılaştırma

Vitrin, [AltTab](https://github.com/lwouis/alt-tab-macos)'tan esinlenmiştir ve AltTab ile bağlantılı
değildir. Arama, simge ve başlık görünümleri, otomatik boyutlandırma ve birden fazla kısayol
AltTab'da ücretli sürümdedir; Vitrin'de bunlar Görev Görünümü ile birlikte ücretsizdir.

## Katkıda bulunma

`swift build` ve `swift test` projeyi derler ve test eder; `scripts/build-app.sh` uygulama paketini
oluşturur. Ayrıntılar için [CONTRIBUTING.md](CONTRIBUTING.md).

## Lisans

[GPL-3.0](LICENSE)
