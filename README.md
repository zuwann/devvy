# Devvy

[English](#english) | [Italiano](#italiano)

---

## English

**Devvy: signed drivers from the Microsoft catalog, verified before install.** Open source driver cleaner and updater for Windows 10/11 - free, no ads, no accounts, nothing installed.

Devvy is a light and transparent tool to maintain, update and clean up drivers and devices on Windows. Unlike commercial "driver booster" tools it installs no service, bundles nothing and never forces updates you do not need. It starts a small local web server (only `127.0.0.1`) and runs plain PowerShell scripts (`.ps1`) that you can read, with a web page as the interface. When you close it, nothing stays running.

> **Status: experimental beta (0.10.155).** Written and tested mostly on Linux with simulated Windows functions, then used on real PCs by the author. Use it at your own risk and read the [DISCLAIMER](DISCLAIMER.txt) and the Safety section.

### Why it is different

- **Official sources only.** Drivers come from the Microsoft Update Catalog, matched by the exact hardware ID of your devices. The signature of every downloaded package is checked and its SHA-256 is shown and logged; a package with a missing or wrong signature is refused.
- **Cleans what is left behind.** Finds ghost devices, old or unused driver versions and stale Bluetooth pairings, and explains in plain words what each one is and whether it is safe to remove. Drivers in use are never offered for removal.
- **Safety first.** On request it creates a restore point and a copy of the drivers before any change, and it can stop Windows from installing again the drivers you removed. Everything is previewed before it is applied.
- **Privacy by design.** No names, serial numbers or history leave the PC. The catalog search sends only hardware codes (`VEN_xxxx&DEV_xxxx[&SUBSYS_xxxxxxxx]`: chip and board maker, never a serial number), only when you press Search. No telemetry, no accounts.
- **Transparent.** A "What it does" help popup (the ? icon) inside the program lists what it reads, what it changes, what goes online, where the files are, and the fingerprints of the files you are running.

### How it works

1. You start the self-elevating batch file (`devvy.bat`).
2. A light local web server starts and the page opens in your browser.
3. You manage everything from the browser, with a preview before every change.
4. When you exit, the program removes its temporary Defender exceptions and stops; nothing keeps running.

### What it does

- Scans your PC and lists generic, old or missing drivers.
- Searches the Microsoft Update Catalog for matching packages (only a hardware code like `VEN_xxxx&DEV_xxxx[&SUBSYS_xxxxxxxx]` is sent) and installs the ones you choose.
- If Windows keeps using the old driver, it can replace it completely: stop the old driver's services, force the new one and delete the old package, so that after a restart Windows finds only the new one (you decide for each device; drivers built into Windows cannot be deleted).
- Shows a start-screen check of everything the tool needs, with a "Fix it for me" button where it can fix the problem and a short how-to where it cannot.
- For drivers it does not know, shows the hardware ID, the .inf file and its description so you can identify them.
- Also helps tidy up: ghost devices, stale Bluetooth pairings, orphaned or duplicate driver versions.
- Everything is previewed first ("Preview") and you choose which backup to make before any change.

### How to use

1. Extract the whole zip into a normal folder (not OneDrive).
2. Double-click `devvy.bat` and accept the administrator prompt.
3. A page opens in your browser (local only, `127.0.0.1`); the PowerShell window stays open as the engine.
4. On first start confirm the language (detected from Windows), exclusions, Windows Defender exceptions, default backup and data folder. Then follow the tabs: Start, Devices, Drivers, Bluetooth, Updates, Run, Report, Settings.

   **Device management** has four tables, each with a `?` help icon: *Protected from Devvy* (devices Devvy never touches), *Updates hidden in Windows Update* (single driver updates Windows may not install; the device stays free), *Devices blocked from reinstalling* (Windows may not install the device with any driver) and *Drivers installed from the Microsoft catalog* (what Devvy installed, with signature and SHA-256). The Help window has a command list shown as a terminal.

Requirements: Windows 10 2004 (build 19041) or later, Windows PowerShell 5.1 (included), administrator rights, internet for the driver search, the catalog downloads, the knowledge-base update and the web pages of the makers (Devvy tells you if the PC is not connected).
Languages: English, Italian, Spanish, German and French (`scripts/locales/*.json`). To add a language copy `it.json` and translate the values; the English text is the key.
Settings, reports, logs and backups live in the `data` folder (or the folder you choose in Settings).

### Command line and scheduled tasks

From an **administrator** prompt: `devvy.bat /cli Audit -Output json` (read only), `Clean` (preview; add `-Apply` to really remove), `Search` (catalog), `Update [-Apply]`, `Profile -Import file.json` / `-Export file.json`. Full guide: [COMMANDS.md](COMMANDS.md). Exit codes: 0 ok, 1 findings, 2 error, 3 restart needed, 4 not allowed, 5 not administrator. Quote comma lists: `-Parts "devices,drivers"`. Log in `data\logs\cli-*.txt`.
Weekly audit as a scheduled task (run once from an administrator prompt, adjust the path):
`schtasks /Create /TN "Devvy weekly audit" /SC WEEKLY /D MON /ST 09:00 /RL HIGHEST /TR "cmd /c \"C:\Tools\devvy\devvy.bat\" /cli Audit -Output json > \"C:\Tools\devvy-audit.json\""`

### Safety

- No telemetry. The web page listens only on `127.0.0.1`, with a random secret code.
- No change to the PowerShell execution policy (the bypass applies only to the processes started by the `.bat`).
- Backups: restore point and/or export of third-party drivers before any change (your choice).
- Reports, logs and backups may contain device names and your PC/user name: they are excluded by `.gitignore`; never publish them as they are.

### Known limits

- The Microsoft Update Catalog has no official API: the search and download read its web pages and can break if the site changes.
- A newer package is not always better: on branded laptops Windows prefers the manufacturer driver. Devvy checks the result and offers to force the new driver.
- Not verified yet on all Windows editions and languages.
- The translations other than English and Italian are machine-made and not yet reviewed by native speakers.
- "Report a problem" prepares a zip with sensitive data hidden and opens the GitHub issue page: nothing is uploaded by the program, you attach the zip yourself.

License: MIT. Author: zuwann.

---

## Italiano

**Devvy: driver firmati dal catalogo Microsoft, verificati prima dell'installazione.** Strumento open source per pulire e aggiornare i driver di Windows 10/11 - gratuito, senza pubblicità, senza account, senza installazione.

Devvy è uno strumento leggero e trasparente per la manutenzione, l'aggiornamento e la pulizia di driver e dispositivi su Windows. A differenza dei software commerciali tipo "driver booster" non installa servizi, non contiene software aggiuntivo e non forza aggiornamenti inutili. Avvia un piccolo server web locale (solo `127.0.0.1`) ed esegue semplici script PowerShell (`.ps1`) che puoi leggere, con una pagina web come interfaccia. Quando lo chiudi, non resta in esecuzione nulla.

> **Stato: beta sperimentale (0.10.155).** Scritto e provato soprattutto su Linux con funzioni Windows simulate, poi usato su PC reali dall'autore. Usalo a tuo rischio e leggi il [DISCLAIMER](DISCLAIMER.txt) e la sezione Sicurezza.

### Perché è diverso

- **Solo fonti ufficiali.** I driver arrivano dal Catalogo Microsoft Update, scelti con l'ID hardware esatto dei tuoi dispositivi. La firma di ogni pacchetto scaricato viene controllata e il suo SHA-256 viene mostrato e salvato; un pacchetto con firma mancante o errata viene rifiutato.
- **Pulisce ciò che resta.** Trova dispositivi fantasma, versioni di driver vecchie o inutilizzate e abbinamenti Bluetooth obsoleti, e spiega in parole semplici cos'è ciascuno e se si può rimuovere in sicurezza. I driver in uso non vengono mai proposti per la rimozione.
- **Prima la sicurezza.** Su richiesta crea un punto di ripristino e una copia dei driver prima di ogni modifica, e può impedire a Windows di reinstallare i driver che hai rimosso. Tutto viene mostrato in anteprima prima di essere applicato.
- **Privacy fin dalla progettazione.** Nessun nome, numero di serie o cronologia lascia il PC. La ricerca nel catalogo invia solo codici hardware (`VEN_xxxx&DEV_xxxx[&SUBSYS_xxxxxxxx]`: chip e produttore della scheda, mai un numero di serie), solo quando premi Cerca. Niente telemetria, niente account.
- **Trasparente.** Un popup di aiuto "Cosa fa" (icona ?) dentro il programma elenca cosa legge, cosa cambia, cosa va online, dove sono i file e le impronte dei file che stai eseguendo.

### Come funziona

1. Avvii il file batch che si eleva da solo (`devvy.bat`).
2. Parte un leggero server web locale e la pagina si apre nel browser.
3. Gestisci tutto dal browser, con un'anteprima prima di ogni modifica.
4. Quando esci, il programma toglie le sue eccezioni temporanee di Defender e si ferma; non resta in esecuzione nulla.

### Cosa fa

- Analizza il PC ed elenca i driver generici, vecchi o mancanti.
- Cerca nel Catalogo Microsoft Update i pacchetti adatti (viene inviato solo un codice hardware come `VEN_xxxx&DEV_xxxx[&SUBSYS_xxxxxxxx]`) e installa quelli che scegli.
- Se Windows continua a usare il vecchio driver, può sostituirlo completamente: ferma i servizi del vecchio driver, forza quello nuovo e cancella il vecchio pacchetto, così dopo un riavvio Windows trova solo il nuovo (decidi tu per ogni dispositivo; i driver integrati in Windows non si possono cancellare).
- Mostra nella schermata iniziale un controllo di tutto ciò che serve allo strumento, con un pulsante "Sistema per me" dove può risolvere il problema e una breve guida dove non può.
- Per i driver che non conosce, mostra l'ID hardware, il file .inf e la sua descrizione, così puoi identificarli.
- Aiuta anche a fare ordine: dispositivi fantasma, abbinamenti Bluetooth obsoleti, versioni di driver orfane o duplicate.
- Tutto viene prima mostrato in anteprima ("Anteprima") e scegli tu quale backup fare prima di ogni modifica.

### Come si usa

1. Estrai tutto lo zip in una cartella normale (non OneDrive).
2. Fai doppio clic su `devvy.bat` e accetta la richiesta di amministratore.
3. Si apre una pagina nel browser (solo locale, `127.0.0.1`); la finestra PowerShell resta aperta come motore.
4. Al primo avvio conferma lingua (rilevata da Windows), esclusioni, eccezioni di Windows Defender, backup predefinito e cartella dei dati. Poi segui le schede: Inizia, Dispositivi, Driver, Bluetooth, Aggiornamenti, Esegui, Report, Impostazioni.

   **Gestione dispositivi** ha quattro tabelle, ognuna con l'icona di aiuto `?`: *Protetti da Devvy* (dispositivi che Devvy non tocca), *Aggiornamenti nascosti in Windows Update* (singoli aggiornamenti di driver che Windows non installa; il dispositivo resta libero), *Dispositivi bloccati dalla reinstallazione* (Windows non può installare il dispositivo con nessun driver) e *Driver installati dal catalogo Microsoft* (cosa ha installato Devvy, con firma e SHA-256). La finestra Aiuto mostra l'elenco dei comandi come in un terminale.

Requisiti: Windows 10 2004 (build 19041) o successivo, Windows PowerShell 5.1 (incluso), diritti di amministratore, internet per la ricerca dei driver, i download dal catalogo, l'aggiornamento della base di conoscenza e le pagine web dei produttori (Devvy ti avvisa se il PC non è connesso).
Lingue: inglese, italiano, spagnolo, tedesco e francese (`scripts/locales/*.json`). Per aggiungere una lingua copia `it.json` e traduci i valori; il testo inglese è la chiave.
Impostazioni, report, log e backup stanno nella cartella `data` (o nella cartella scelta nelle Impostazioni).

### Riga di comando e attività pianificate

Da un prompt **amministratore**: `devvy.bat /cli Audit -Output json` (sola lettura), `Clean` (anteprima; con `-Apply` rimuove davvero), `Search` (catalogo), `Update [-Apply]`, `Profile -Import file.json` / `-Export file.json`. Full guide: [COMMANDS.md](COMMANDS.md). Codici di uscita: 0 ok, 1 trovato qualcosa, 2 errore, 3 serve riavvio, 4 non consentito, 5 non amministratore. Le liste con virgole vanno tra virgolette: `-Parts "devices,drivers"`. Log in `data\logs\cli-*.txt`.
Controllo settimanale come attività pianificata (da eseguire una volta da prompt amministratore, adatta il percorso): vedi l'esempio `schtasks` nella sezione inglese.

### Sicurezza

- Nessuna telemetria. La pagina web ascolta solo su `127.0.0.1`, con un codice segreto casuale.
- Nessuna modifica alla policy di esecuzione di PowerShell (il bypass vale solo per i processi avviati dal `.bat`).
- Backup: punto di ripristino e/o esportazione dei driver di terze parti prima di ogni modifica (a tua scelta).
- Report, log e backup possono contenere nomi di dispositivi e il nome del PC/utente: sono esclusi da `.gitignore`; non pubblicarli mai così come sono.

### Limiti noti

- Il Catalogo Microsoft Update non ha un'API ufficiale: la ricerca e il download leggono le sue pagine web e possono smettere di funzionare se il sito cambia.
- Un pacchetto più recente non è sempre migliore: sui portatili di marca Windows preferisce il driver del produttore. Devvy controlla il risultato e propone di forzare il driver nuovo.
- Non ancora verificato su tutte le edizioni e lingue di Windows.
- Le traduzioni diverse da inglese e italiano sono automatiche e non ancora riviste da madrelingua.
- "Segnala un problema" prepara uno zip con i dati sensibili nascosti e apre la pagina delle segnalazioni su GitHub: il programma non carica nulla, lo zip lo alleghi tu.

Licenza: MIT. Autore: zuwann.
