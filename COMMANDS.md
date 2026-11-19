# Devvy on the command line

Everything the web page does can be done from a terminal, without opening the browser. The questions of the scripts (for example the [F]/[S]/[M] choice when Windows keeps using the old driver) appear in the same window and you answer with one key. **The Italian version of this guide is below.**

## Before you start

- Use a **Command Prompt or PowerShell started as administrator** (the `-h` help also works without). The command line never asks for elevation by itself: without administrator rights it prints an error and exits with code 5.
- Go to the Devvy folder: `cd /d C:\Path\devvy`
- Syntax: `devvy.bat /cli <Action> [options]`. In PowerShell write `.\devvy.bat ...`.
- **Web page**: `devvy.bat /gui` (same as `devvy.bat` alone) starts the local server and opens the browser; it asks for administrator rights if needed.
- **Help**: `devvy.bat -h` (or `/?` or `/help`), in the language of Devvy.
- Comma lists go in quotes: `-Parts "devices,drivers"`.
- Language, exclusions and options are the ones saved in the settings (`data\settings.json`), the same as the page.
- Every run writes a log in `data\logs\cli-<date>.txt` and, at the end, prints the **exit code** with its meaning.

## Actions

| Command | What it does | Changes something? |
|---|---|---|
| `Check` | System check (requirements). With `-Fix` it repairs what can be repaired (asks first when you are at the keyboard) | Only with -Fix |
| `Inventory` | Creates the inventory of devices, drivers and Bluetooth | No |
| `Audit` | Inventory and summary: ghost devices, old drivers, old Bluetooth pairings, drivers to check | No |
| `Clean` | Preview of the cleanup | No |
| `Clean -Apply` | Real cleanup (ghost devices, unused drivers, old versions, Bluetooth). Asks for backup and confirmation, repeats while more leftovers appear (max 4 rounds) | **Yes** |
| `Clean -Apply -Review` | Same, but first shows the suggested rows so you can choose which to KEEP | **Yes** |
| `Search` | Looks in the Microsoft catalog for newer drivers and lists them | No |
| `Install` | Searches (if needed) and shows the catalog drivers; you choose which to install; without -Apply it is only a preview | No |
| `Install -Apply` | Installs the chosen drivers: backup, confirmation, risk question for delicate classes, then the [F]/[S]/[M] questions | **Yes** |
| `Rollback` | Lists the drivers replaced by Devvy and goes back to the previous one (`-Apply` or confirmation at the keyboard) | **Yes** |
| `Report` | Creates the HTML report and prints where it is | Writes the file |
| `Problem` | Creates the anonymous problem zip to attach to a GitHub issue | Writes the file |
| `Share` | Creates the anonymous copies of the reports for the knowledge base | Writes the file |
| `Defender Status` / `On` / `Off` | Shows, adds or removes the temporary Microsoft Defender exceptions | `On`/`Off` yes |
| `Exclusions List` / `Add "<name>"` / `Remove "<name>"` | Devices Devvy never touches | Add/Remove yes |
| `Blocked List` / `Remove <id>` | IDs Windows is stopped from reinstalling; Remove undoes the block | Remove yes |
| `Settings Show` / `Set <name>=<value>` | Shows or changes the settings: language, defender (ask/always/never), backup (ask/full/drivers/none), catalogConsent, postRebootCheck, updateCheck, inventoryAtStart, blockReinstall | Set yes |
| `KbUpdate` | Updates the knowledge base from GitHub | Writes in data\kb |
| `PostCheck` | Check after a restart (network, screen, devices with errors) | No |
| `Update` / `Update -Apply` | Checks for a newer Devvy; with -Apply it downloads it, checks the SHA-256 and installs it | -Apply yes |
| `Profile -Export file.json` / `-Import file.json` | Saves or adds the profile (exclusions, options, own rows). Import only adds | Import yes |
| `Restart` | Restarts Windows (asks first) | Yes |

## Options

| Option | Meaning |
|---|---|
| `-Output text` / `-Output json` | Colored text (default) or one JSON object for scripts. No questions in json |
| `-Apply` | Really do it (Clean, Install, Rollback, Update). Without it nothing changes |
| `-Yes` | Do not ask for confirmations (scripts). Driver questions still get the cautious answer |
| `-Parts "devices,drivers,oldversions,bluetooth"` | With `Clean`: what to clean (default: all) |
| `-Backup none\|drivers\|full` | With `-Apply`: backup before changing. If missing: taken from the settings, otherwise asked (no keyboard: none) |
| `-Review` | With `Clean -Apply`: choose which suggested items to keep |
| `-Select newest` / `1,3` / `all` | With `Install`: which drivers. `newest` = the newest of each device, risky classes excluded |
| `-AcceptRisk` | With `Install`: accept risky drivers (screen, network, system, USB...) |
| `-Key <id>` | With `Rollback`: choose the driver without asking |
| `-Fix` | With `Check`: repair |
| `-Restart` | Restart Windows at the end if needed |

## Questions and confirmations

- **At the keyboard** (normal window): before changing anything it asks for confirmation ("Apply the changes now? [Y/N]"), asks for the backup if you did not give it, asks your consent for risky drivers, shows the [F]/[S]/[M] questions of the installation and offers the restart at the end if needed.
- **Without a keyboard** (scheduled task, `-Output json` or `-Yes`): no questions. Cautious answers are used: risky drivers are never confirmed by themselves, N/M is answered to the scripts, Windows is not restarted (unless `-Restart`).
- Microsoft Defender exceptions follow the `defender` setting: `always` adds them at the start of every command that changes something and removes them at the end, `ask` asks, `never` does nothing.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | All fine / done |
| 1 | Something found (Audit, Clean preview, Search with newer drivers, Install without -Apply, update available) |
| 2 | Error (see the log) |
| 3 | Restart needed |
| 4 | Not allowed (catalog switched off in the settings) |
| 5 | Not administrator |

The code is **printed at the end of the command** ("Exit code N: ..."). In a script: PowerShell `$LASTEXITCODE`, cmd `echo %errorlevel%` (`%errorlevel%` does NOT work in PowerShell).

## Examples

```
devvy.bat /gui
devvy.bat /cli Audit
devvy.bat /cli Audit -Output json > audit.json
devvy.bat /cli Clean -Parts "devices,bluetooth"
devvy.bat /cli Clean -Apply -Backup drivers
devvy.bat /cli Clean -Apply -Review
devvy.bat /cli Install
devvy.bat /cli Install -Apply -Select newest -Backup full
devvy.bat /cli Install -Apply -Select 2 -AcceptRisk
devvy.bat /cli Rollback
devvy.bat /cli Exclusions Add "Intel(R) UHD Graphics 630"
devvy.bat /cli Settings Set defender=always
devvy.bat /cli Update -Apply
```

## Scheduled task (weekly audit)

From an administrator prompt, once (adjust the paths):

```
schtasks /Create /TN "Devvy weekly audit" /SC WEEKLY /D MON /ST 09:00 /RL HIGHEST /TR "cmd /c \"C:\Tools\devvy\devvy.bat\" /cli Audit -Output json > \"C:\Tools\devvy-audit.json\""
```

To check for program updates every week use `Update` instead of `Audit`. Do not schedule `Clean -Apply` or `Install -Apply` before trying them by hand: they really change the PC.

## Notes

- A network folder works, but an administrator prompt does not see the mapped drives of the normal user: use the UNC path (`\\server\folder`).
- User names with special characters (such as the exclamation mark) are supported.
- `Update -Apply` also replaces `devvy.bat` at the end: nothing needs to be restarted.

---

# Devvy da riga di comando (italiano)

Tutto quello che fa la pagina web si può fare anche da terminale, senza aprire il browser. Le domande degli script (per esempio la scelta [F]/[S]/[M] quando Windows continua a usare il vecchio driver) compaiono nella stessa finestra e rispondi con un tasto.

## Prima di iniziare

- Serve un **prompt dei comandi o PowerShell avviato come amministratore** (l'aiuto `-h` funziona anche senza). La riga di comando non chiede mai l'elevazione da sola: senza diritti stampa un errore ed esce con codice 5.
- Spostati nella cartella di Devvy: `cd /d C:\Percorso\devvy`
- Sintassi: `devvy.bat /cli <Azione> [opzioni]`. In PowerShell scrivi `.\devvy.bat ...`.
- **Pagina web**: `devvy.bat /gui` (come `devvy.bat` da solo) avvia il server locale e apre il browser; chiede l'amministratore se serve.
- **Aiuto**: `devvy.bat -h` (oppure `/?` o `/help`).
- Le liste con la virgola vanno tra virgolette: `-Parts "devices,drivers"`.
- Lingua, eccezioni e opzioni sono quelle salvate nelle impostazioni (`data\settings.json`), le stesse della pagina.
- Ogni esecuzione scrive un log in `data\logs\cli-<data>.txt` e, a fine comando, stampa il **codice di uscita** con il suo significato.

## Azioni

| Comando | Cosa fa | Cambia qualcosa? |
|---|---|---|
| `Check` | Controllo del sistema (requisiti). Con `-Fix` ripara ciò che si può riparare (chiede conferma se sei alla tastiera) | Solo con -Fix |
| `Inventory` | Crea l'inventario di dispositivi, driver e Bluetooth | No |
| `Audit` | Inventario e riepilogo: fantasmi, driver vecchi, Bluetooth vecchi, driver da controllare | No |
| `Clean` | Anteprima della pulizia | No |
| `Clean -Apply` | Pulizia vera (fantasmi, driver non usati, vecchie versioni, Bluetooth). Chiede backup e conferma, ripete finché compaiono altri residui (max 4 giri) | **Sì** |
| `Clean -Apply -Review` | Come sopra, ma prima ti mostra le righe suggerite e puoi scegliere quali TENERE | **Sì** |
| `Search` | Cerca nel catalogo Microsoft driver più nuovi e li elenca | No |
| `Install` | Cerca (se serve) e mostra i driver del catalogo; ti fa scegliere quali installare; senza -Apply è solo un'anteprima | No |
| `Install -Apply` | Installa i driver scelti: backup, conferma, rischio per le classi delicate, poi le domande [F]/[S]/[M] | **Sì** |
| `Rollback` | Elenca i driver sostituiti da Devvy e torna a quello precedente (`-Apply` o conferma alla tastiera) | **Sì** |
| `Report` | Crea il report HTML e stampa dove si trova | Scrive il file |
| `Problem` | Crea lo zip anonimo del problema, da allegare a una segnalazione su GitHub | Scrive il file |
| `Share` | Crea le copie anonime dei report per la base di conoscenza | Scrive il file |
| `Defender Status` / `On` / `Off` | Mostra, aggiunge o toglie le eccezioni temporanee di Microsoft Defender | `On`/`Off` sì |
| `Exclusions List` / `Add "<nome>"` / `Remove "<nome>"` | Dispositivi che Devvy non tocca mai | Add/Remove sì |
| `Blocked List` / `Remove <id>` | ID che Windows non può reinstallare; Remove annulla il blocco | Remove sì |
| `Settings Show` / `Set <nome>=<valore>` | Mostra o cambia le impostazioni: language, defender (ask/always/never), backup (ask/full/drivers/none), catalogConsent, postRebootCheck, updateCheck, inventoryAtStart, blockReinstall | Set sì |
| `KbUpdate` | Aggiorna la base di conoscenza da GitHub | Scrive in data\kb |
| `PostCheck` | Controllo dopo un riavvio (rete, schermo, dispositivi con errori) | No |
| `Update` / `Update -Apply` | Controlla se c'è una versione nuova di Devvy; con -Apply la scarica, verifica gli SHA-256 e la installa | -Apply sì |
| `Profile -Export file.json` / `-Import file.json` | Salva o aggiunge il profilo (eccezioni, opzioni, righe personali). L'import aggiunge soltanto | Import sì |
| `Restart` | Riavvia Windows (chiede prima) | Sì |

## Opzioni

| Opzione | Significato |
|---|---|
| `-Output text` / `-Output json` | Testo colorato (predefinito) oppure un solo oggetto JSON per gli script. In json non si fanno domande |
| `-Apply` | Esegue davvero (Clean, Install, Rollback, Update). Senza, non cambia nulla |
| `-Yes` | Non chiede conferme (per gli script). Le domande dei driver ricevono comunque la risposta prudente |
| `-Parts "devices,drivers,oldversions,bluetooth"` | Con `Clean`: cosa pulire (predefinito: tutto) |
| `-Backup none\|drivers\|full` | Con `-Apply`: backup prima di cambiare. Se manca: lo prende dalle impostazioni, altrimenti lo chiede (senza tastiera: nessuno) |
| `-Review` | Con `Clean -Apply`: scegli quali elementi suggeriti tenere |
| `-Select newest` / `1,3` / `all` | Con `Install`: quali driver. `newest` = il più nuovo di ogni dispositivo, escluse le classi rischiose |
| `-AcceptRisk` | Con `Install`: accetta i driver rischiosi (schermo, rete, sistema, USB...) |
| `-Key <id>` | Con `Rollback`: sceglie il driver senza chiedere |
| `-Fix` | Con `Check`: ripara |
| `-Restart` | Riavvia Windows alla fine se serve |

## Domande e conferme

- **Alla tastiera** (finestra normale): prima di cambiare qualcosa chiede conferma ("Applicare ora le modifiche? [Y/N]"), chiede il backup se non l'hai indicato, chiede il consenso per i driver rischiosi, mostra le domande [F]/[S]/[M] dell'installazione e alla fine propone il riavvio se serve.
- **Senza tastiera** (attività pianificata, `-Output json` o `-Yes`): niente domande. Usa risposte prudenti: non conferma da solo i driver rischiosi, risponde N/M alle domande degli script, non riavvia (a meno di `-Restart`).
- Le eccezioni di Microsoft Defender seguono l'impostazione `defender`: `always` le aggiunge all'inizio dei comandi che cambiano qualcosa e le toglie alla fine, `ask` lo chiede, `never` no.

## Codici di uscita

| Codice | Significato |
|---|---|
| 0 | Tutto a posto / fatto |
| 1 | Trovato qualcosa (Audit, anteprima Clean, Search con driver più nuovi, Install senza -Apply, Update disponibile) |
| 2 | Errore (vedi il log) |
| 3 | Serve riavviare Windows |
| 4 | Non consentito (catalogo disattivato nelle impostazioni) |
| 5 | Non sei amministratore |

Il codice viene **stampato a fine comando** ("Codice di uscita N: ..."). Per leggerlo in uno script: PowerShell `$LASTEXITCODE`, cmd `echo %errorlevel%` (in PowerShell `%errorlevel%` NON funziona).

## Esempi

```
devvy.bat /cli Audit
devvy.bat /cli Audit -Output json > audit.json
devvy.bat /cli Clean -Parts "devices,bluetooth"
devvy.bat /cli Clean -Apply -Backup drivers
devvy.bat /cli Clean -Apply -Review
devvy.bat /cli Install
devvy.bat /cli Install -Apply -Select newest -Backup full
devvy.bat /cli Install -Apply -Select 2 -AcceptRisk
devvy.bat /cli Rollback
devvy.bat /cli Exclusions Add "Intel(R) UHD Graphics 630"
devvy.bat /cli Settings Set defender=always
devvy.bat /cli Update -Apply
```

## Attività pianificata (controllo settimanale)

Da un prompt amministratore, una volta (adatta i percorsi):

```
schtasks /Create /TN "Devvy weekly audit" /SC WEEKLY /D MON /ST 09:00 /RL HIGHEST /TR "cmd /c \"C:\Tools\devvy\devvy.bat\" /cli Audit -Output json > \"C:\Tools\devvy-audit.json\""
```

Per controllare gli aggiornamenti del programma ogni settimana usa `Update` al posto di `Audit`.
Non pianificare `Clean -Apply` o `Install -Apply` senza averli provati prima a mano: cambiano davvero il PC.

## Note

- Una cartella di rete va bene, ma il prompt amministratore non vede le unità mappate dell'utente normale: usa il percorso UNC (`\\server\cartella`).
- I nomi utente con caratteri speciali (come il punto esclamativo) sono supportati.
- `Update -Apply` sostituisce anche `devvy.bat` a fine lavoro: non serve riavviare nulla.
