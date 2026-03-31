# work2md

[English](README.md) | Magyar

A `work2md` egy CLI eszközkészlet Jira issue-k és Confluence Cloud oldalak
Markdown csomagokba exportálásához, amelyek jól használhatók dokumentációhoz,
biztonsági mentésekhez, automatizáláshoz és AI-orientált munkafolyamatokhoz.

- a `jira2md` Jira issue-kat exportál
- a `confluence2md` Confluence Cloud oldalakat exportál
- a `work2md-config` a közös hitelesítési adatok és ellenőrzés kezelésére szolgál

A projekt független, harmadik féltől származó eszköz, és nem áll kapcsolatban
az Atlassiannel, illetve nem az Atlassian támogatja vagy hagyja jóvá.

## Licencelési megjegyzés

Ez a repository szándékosan nyílt forráskódú licenc nélkül van közzétéve.
Az alkalmazandó jog által megengedett eseteket kivéve semmilyen jog nem kerül
engedélyezésre a kód használatára, módosítására vagy továbbterjesztésére a
jogtulajdonos kifejezett engedélye nélkül.

## Projektállapot

Az aktuális kiadási ág `0.9.x`. Az eszköz már most is hasznos a napi munkában,
de még pre-`1.0` állapotú projekt, ezért a CLI részletei és a kimeneti
konvenciók még változhatnak.

## Funkciók

- Tartalmat, metaadatokat, kommenteket és letöltött csatolmányokat exportál kis
  csomagként egyetlen fájl helyett
- Elfogad Jira issue kulcsokat, Jira issue URL-eket, Confluence oldalazonosítókat
  és Confluence oldal URL-eket
- Egy közös konfigurációs fájlon keresztül osztja meg a Jira és Confluence
  hitelesítési adatokat
- A tokeneket konfigurációs fájlban, támogatott rendszerkulcstartóban vagy
  környezeti változókban tárolja
- Egyetlen artefaktumot tud stdout-ra írni pipe-okhoz és automatizáláshoz
- AI-barát exportokat készít LLM-ingestion és RAG pipeline-ok számára
- Opcionális YAML front mattert ad az `index.md` elejére
- Kitakarja az email-címeket, account ID-kat, belső URL-eket vagy kiválasztott
  metaadatmezőket
- Batch exportot támogat input fájlokon, Jira JQL-en vagy Confluence CQL-en
  keresztül
- Manifest-alapú `--incremental` móddal újrahasznosítja a változatlan export
  csomagokat
- Figyelmeztet, ha a konfigurált API token érvénytelen, lejárt vagy hamarosan
  lejár

## Telepítés

### Ubuntu vagy Debian

Töltsd le a legfrissebb `.deb` csomagot a GitHub Releases oldalról, majd
telepítsd `apt`-tal:

```bash
sudo apt install ./work2md_<version>_all.deb
```

Telepített parancsok:

- `jira2md`
- `confluence2md`
- `work2md-config`

A csomag deklarálja a futásidejű függőségeit, így az `apt` ezeket
automatikusan telepíti.

### Homebrew Linuxon

Vedd fel a repositoryt tapként, majd telepítsd a `work2md`-t Homebrew-val:

```bash
brew tap green-zen-monk/work2md https://github.com/green-zen-monk/work2md
brew install work2md
```

A Homebrew ugyanazokat a parancsokat telepíti a brew prefix alatt:

- `jira2md`
- `confluence2md`
- `work2md-config`

A Homebrew formula a taggelt GitHub release-eket követi. Nem kiadott checkout
esetén használd az alábbi Linux portable `tar.gz` utat.

### Linux portable tar.gz

Töltsd le a portable archívumot a GitHub Releases oldalról, csomagold ki, majd
helyezd a könyvtárat a `PATH`-odra:

```bash
tar -xzf work2md_<version>_portable.tar.gz
cd work2md-<version>
export PATH="$PWD:$PATH"
```

Portable futásidejű függőségek:

- `bash`
- `curl`
- `python3`

## Gyors kezdés

Inicializáld a közös konfigurációt:

```bash
work2md-config init
```

Vagy konfiguráld külön a szolgáltatásokat:

```bash
work2md-config jira init
work2md-config confluence init
```

Ezután exportáld a tartalmat:

```bash
jira2md PROJ-123
confluence2md 123456789
```

Alapértelmezés szerint az exportok ide kerülnek:

- `./docs/jira/<issue-key>/`
- `./docs/confluence/<page-id>-<slug>/`

## Konfiguráció

A közös konfiguráció itt tárolódik:

```bash
~/.config/work2md/config
```

A `work2md-config` a szülőkönyvtárat priváttá teszi (`0700`), magát a
konfigurációs fájlt pedig szintén priváttá (`0600`). Ha egy régebbi fájl ennél
lazább jogosultságokkal rendelkezik, az eszköz olvasás vagy írás előtt
automatikusan szigorítja azokat.

Token backendek:

- `config`: a tokent a `~/.config/work2md/config` fájlban tárolja
- `keyring`: a tokent a Linux desktop kulcstartóban tárolja `secret-tool`
  segítségével
- environment variables: futásidőben felülírják a tárolt tokent

Példa:

```bash
work2md-config jira set base https://company.atlassian.net
work2md-config jira set email you@example.com
work2md-config jira set token-backend keyring
work2md-config jira set token <jira-api-token>

work2md-config confluence set base https://company.atlassian.net
work2md-config confluence set email you@example.com
work2md-config confluence set token-backend keyring
work2md-config confluence set token <confluence-api-token>
```

Környezeti felülírási példa:

```bash
export WORK2MD_JIRA_TOKEN='<jira-api-token>'
export WORK2MD_CONFLUENCE_TOKEN='<confluence-api-token>'
```

Hasznos konfigurációs parancsok:

```bash
work2md-config path
work2md-config show
work2md-config validate
work2md-config doctor
```

A `work2md-config validate` ellenőrzi, hogy a szükséges mezők léteznek-e, és
hogy egy élő, hitelesített kérés sikeresen lefut-e. A `work2md-config doctor`
ennél részletesebb diagnosztikát ad, például a base URL érvényességéről, a
token forrásáról, a keyring elérhetőségéről és a token lejárati állapotáról.

### `work2md-config` parancsútmutató

Használd a `work2md-config` parancsot a közös beállítások kezelésére, amelyeket
mindkét exportáló olvas.

- `work2md-config init`: interaktívan inicializálja egy futásban a Jira és
  Confluence beállításokat
- `work2md-config jira init`: csak a Jira beállításokat inicializálja vagy
  frissíti
- `work2md-config confluence init`: csak a Confluence beállításokat
  inicializálja vagy frissíti
- `work2md-config show`: kiírja az aktuális konfigurációt maszkolt titkokkal
- `work2md-config validate`: ellenőrzi a szükséges mezőket és élő hitelesített
  API-ellenőrzést futtat
- `work2md-config doctor`: részletesebb állapotjelentést ad, beleértve a token
  forrását, a keyring elérhetőségét és a lejárati figyelmeztetéseket
- `work2md-config path`: kiírja a konfigurációs fájl útvonalát, hogy a
  scriptek felfedezhessék

A `set` alparancs egyszerre egy mezőt frissít:

- `base`: Atlassian site base URL, például `https://company.atlassian.net`
- `email`: az Atlassian fiók email-címe, amelyet az API tokennel együtt használ
- `token`: az API token értéke; a konfigurált backendben tárolódik
- `token-expiry`: opcionális lejárati dátum figyelmeztetésekhez és
  diagnosztikához; elfogad `YYYY-MM-DD` vagy ISO-8601 időbélyeget
- `token-backend`: a token tárolási helye; támogatott értékek: `config` és
  `keyring`

Példák:

```bash
work2md-config jira set base https://company.atlassian.net
work2md-config jira set token-expiry 2026-12-31
work2md-config confluence set token-backend keyring
work2md-config --log-format json validate
```

A `--log-format text|json` elérhető a `work2md-config` parancsban, hogy a shell
scriptek és CI jobok könnyebben tudják feldolgozni a diagnosztikát.

A `keyring` backend jelenleg Linux rendszereket céloz `libsecret-tools`/
`secret-tool` támogatással. Olyan rendszereken, ahol ez a provider nem érhető
el, használd a `config` backendet vagy a környezeti változókat.

## Hitelesítési megjegyzések

A `work2md` jelenleg közvetlenül site-local Atlassian URL-ek ellen hitelesít,
például:

- `https://company.atlassian.net/rest/api/...`
- `https://company.atlassian.net/wiki/rest/api/...`

Ez azt jelenti, hogy a legegyszerűbb támogatott beállítás egy Atlassian API
token, amelyet az Atlassian email-címeddel együtt használsz.

Tokent itt hozhatsz létre:

- <https://id.atlassian.com/manage-profile/security/api-tokens>

A token önmagában nem ad többletjogosultságot. Csak ahhoz a Jira és Confluence
tartalomhoz tud hozzáférni, amelyet az adott Atlassian fiók egyébként is
megtekinthet.

## Használat

Mindkét exportáló ugyanazt a modellt követi:

- pontosan egy inputforrást adsz meg
- alapértelmezés szerint egy Markdown csomagot ír ki
- vagy a `--stdout` használatával egyetlen generált artefaktumot ír ki fájlok
  létrehozása helyett
- a `--front-matter`, `--redact` és `--drop-field` alakító opciókat a kimenet
  véglegesítése előtt alkalmazza

A `--stdout` nem kombinálható a `--output-dir` opcióval, és csak egyetlen elem
exportálásánál támogatott.

### Jira

Parancsformák:

```bash
jira2md ISSUE_KEY_OR_URL [options]
jira2md --input-file PATH [options]
jira2md --jql QUERY [options]
```

Elfogadott inputok:

- `PROJ-123`
- `https://company.atlassian.net/browse/PROJ-123`

Példák:

```bash
jira2md PROJ-123
jira2md PROJ-123 --output-dir ./export
jira2md PROJ-123 --stdout --emit metadata
jira2md PROJ-123 --front-matter
jira2md PROJ-123 --redact email,internal-url --drop-field reporter,url
jira2md PROJ-123 --ai-friendly
jira2md --input-file ./issues.txt --incremental
jira2md --jql 'project = DOCS ORDER BY updated DESC'
```

Mire valók a Jira-specifikus inputok:

- `ISSUE_KEY_OR_URL`: egy issue exportálása, ha már ismered a kulcsot vagy van
  egy böngészős URL-ed
- `--input-file PATH`: sok issue exportálása egy szövegfájlból; az üres sorok
  és a komment sorok figyelmen kívül maradnak
- `--jql QUERY`: a Jira dinamikus issue-halmazt ad vissza, majd az eszköz
  sorban exportálja az eredményeket

### `jira2md` opciók

- `--output-dir PATH`: megváltoztatja a szülőkönyvtárat, ahová a csomagok
  íródnak; az eszköz ezen belül továbbra is issue-nkénti alkönyvtárat hoz létre
- `--stdout`: egyetlen generált dokumentumot ír a standard outputra ahelyett,
  hogy `index.md`, `metadata.md` és `comments.md` fájlokat írna
- `--emit index|metadata|comments`: kiválasztja, hogy a `--stdout` melyik
  generált dokumentumot írja ki
- `--front-matter`: a metaadatokat YAML front matterré alakítja, és az
  `index.md` elejére illeszti
- `--redact RULES`: kitakarja az érzékeny értékosztályokat a generált
  Markdownból; megosztás vagy indexelés előtti használatra hasznos
- `--drop-field FIELDS`: eltávolít kiválasztott metaadatkulcsokat a
  `metadata.md`-ből és a generált front matterből
- `--ai-friendly`: egy további `-ai` csomagot készít lineárisabb
  tartalomprofillal LLM vagy RAG ingestion számára
- `--incremental`: újrahasznosítja a meglévő csomagot, ha a forrástartalom és
  az exportopciók nem változtak
- `--log-format text|json`: emberi vagy gépi feldolgozásra formázza a stderr
  naplókat
- `--version`: kiírja a telepített verziót

Tipikus `jira2md` munkafolyamatok:

- dokumentációs mentés: `jira2md PROJ-123 --output-dir ./export`
- pipeline handoff: `jira2md PROJ-123 --stdout --emit index`
- publikálás statikus oldalakra: `jira2md PROJ-123 --front-matter`
- adatvédelmi szempontú exportok: `jira2md PROJ-123 --redact email,internal-url`
- nagy, visszatérő szinkronok: `jira2md --jql 'project = DOCS' --incremental`

### Confluence

Parancsformák:

```bash
confluence2md PAGE_ID_OR_URL [options]
confluence2md --input-file PATH [options]
confluence2md --cql QUERY [options]
```

Elfogadott inputok:

- `123456789`
- `https://company.atlassian.net/wiki/spaces/TEAM/pages/123456789/Page+Title`

Példák:

```bash
confluence2md 123456789
confluence2md 123456789 --output-dir ./export
confluence2md 123456789 --stdout --emit comments
confluence2md 123456789 --front-matter
confluence2md 123456789 --redact email,account-id --drop-field url
confluence2md 123456789 --ai-friendly
confluence2md --input-file ./pages.txt --incremental
confluence2md --cql 'type = page order by lastmodified desc'
```

Mire valók a Confluence-specifikus inputok:

- `PAGE_ID_OR_URL`: egy ismert oldal exportálása numerikus azonosító vagy oldal
  URL alapján
- `--input-file PATH`: egy fájlban felsorolt sok oldal exportálása
- `--cql QUERY`: a Confluence a keresési feltételek alapján állít elő egy
  oldallistát, majd az eszköz exportálja a találatokat

### `confluence2md` opciók

A legtöbb opció ugyanúgy működik, mint a `jira2md` esetén:

- `--output-dir PATH`: másik alapkönyvtár alá írja a csomagokat
- `--stdout`: egyetlen generált artefaktumot ír ki fájlok írása helyett
- `--emit index|metadata|comments`: kiválasztja, melyik artefaktumot adja
  vissza a `--stdout`
- `--front-matter`: YAML front mattert illeszt az `index.md` elejére
- `--redact RULES`: eltávolít érzékeny osztályokat, például email-címeket,
  account ID-kat vagy belső URL-eket a generált Markdownból
- `--drop-field FIELDS`: eltávolít kiválasztott metaadatkulcsokat a
  `metadata.md` és a front matter kiírása előtt
- `--ai-friendly`: egy további `-ai` exportkönyvtárat hoz létre
- `--incremental`: a `manifest.json` alapján kihagyja a változatlan oldalak
  újraírását
- `--log-format text|json`: sima szöveges vagy géppel olvasható naplókat ad
- `--version`: kiírja a telepített verziót

A fő Confluence-specifikus különbség a batch query mód:

- a `--cql QUERY` Confluence keresési szintaxist használ a Jira JQL helyett
- az oldalexportok `<page-id>-<slug>/` alá íródnak, így az ismétlődő címek is
  megkülönböztethetők maradnak

### Közös redaction és metaadatvezérlők

A `--redact` vesszővel elválasztott listát fogad. A támogatott osztályok:

- `email`: email-címek kitakarása
- `account-id`: Atlassian account azonosítók kitakarása
- `internal-url`: azokra az URL-ekre vonatkozó kitakarás, amelyek visszamutatnak
  a konfigurált Atlassian site-ra

A `--drop-field` szintén vesszővel elválasztott listát fogad. Akkor használd,
ha a tartalomtörzs érintetlen maradjon, de bizonyos metaadat-bejegyzések ne
kerüljenek bele a `metadata.md`-be vagy a front matterbe. Gyakori példák: `url`,
`reporter`, `assignee` és `updated_by`.

## Kimeneti struktúra

Egy normál export ilyen csomagot ír:

```text
docs/
  jira/
    PROJ-123/
      index.md
      metadata.md
      comments.md
      manifest.json
      assets/
  confluence/
    123456789-page-title/
      index.md
      metadata.md
      comments.md
      manifest.json
      assets/
```

- az `index.md` tartalmazza a fő törzstartalmat
- a `metadata.md` tartalmazza a forrásspecifikus metaadatokat
- a `comments.md` tartalmazza az exportált kommenteket
- a `manifest.json` fingerprint-eket és csatolmány-metaadatokat tárol az
  inkrementális újrafelhasználáshoz

A `--stdout` használatakor a támogatott `--emit` célok:

- `index`
- `metadata`
- `comments`

## Front matter, redaction és AI-friendly output

Használd a `--front-matter` opciót, ha YAML front mattert szeretnél az
`index.md` elejére statikus oldalas pipeline-okhoz.

Használd a `--redact` opciót egy vagy több vesszővel elválasztott szabállyal:

- `email`
- `account-id`
- `internal-url`

Használd a `--drop-field` opciót, ha bizonyos metaadatkulcsokat el akarsz
távolítani a `metadata.md` és a generált front matter írása előtt.

A `--ai-friendly` egy második exportkönyvtárat ír `-ai` utótaggal és egy
lineárisabb tartalomprofillal, amely könnyebben feldolgozható LLM-es
munkafolyamatokban.

Példák:

```bash
jira2md PROJ-123 --front-matter --redact email,internal-url --drop-field reporter,url
confluence2md 123456789 --front-matter --redact account-id --drop-field url,updated_by
```

## Batch és inkrementális exportok

Mindkét exportáló egyszerre pontosan egy inputforrást fogad:

- egyetlen Jira issue vagy Confluence oldal
- `--input-file`
- Jira `--jql`
- Confluence `--cql`

A `--incremental` írja és olvassa a `manifest.json` fájlt. Ha a forrástartalom
és az exportopciók nem változtak, a meglévő csomag a helyén marad, és a
csatolmányai újrahasznosíthatók.

## Megjegyzések

- a CLI-k megtagadják a futást `root` felhasználóként
- a Confluence exportok Confluence Cloudot céloznak
- a `~/.config/jira2md/` és `~/.config/confluence2md/` alatti régi
  konfigurációs fájlok továbbra is olvashatók, ha léteznek

## Kiadások

- a `main` ágra érkező pushok és pull requestek futtatják a csomagoló
  workflow-t
- a `main` ágra érkező pushok frissítik a gördülő `edge` GitHub prerelease-t a
  legfrissebb commitból
- az `edge` assetfájlnevek a kiadási ág verzióját és a forrás commit hashét is
  tartalmazzák
- a `v*` mintára illeszkedő Git tagek stabil `.deb` és portable `.tar.gz`
  asseteket publikálnak
- a release- és PPA-lépések dokumentációja itt található:
  [`docs/RELEASING.md`](docs/RELEASING.md)
