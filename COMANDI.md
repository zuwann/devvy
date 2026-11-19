# Devvy da riga di comando (guida / command line guide)

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

---

# English summary

Everything the page does can be done from an **administrator** terminal: `devvy.bat /cli <Action> [options]` (help: `devvy.bat -h`; web page: `devvy.bat /gui`). Script questions ([F]/[S]/[M], confirmations, backup choice) appear in the same window.

- Actions: `Check` `Inventory` `Audit` `Clean` `Search` `Install` `Rollback` `Report` `Problem` `Share` `Defender` `Exclusions` `Blocked` `Settings` `KbUpdate` `PostCheck` `Update` `Profile` `Restart`.
- Options: `-Output text|json`, `-Apply`, `-Yes`, `-Parts`, `-Backup none|drivers|full`, `-Review`, `-Select newest|1,3|all`, `-AcceptRisk`, `-Key`, `-Fix`, `-Restart`.
- Without a keyboard (scheduled task, json, -Yes) no questions are asked: cautious answers are used, risky drivers are never accepted by themselves and Windows is not restarted unless `-Restart`.
- Exit codes: 0 ok, 1 findings / update available, 2 error, 3 restart needed, 4 not allowed, 5 not administrator. The code is printed at the end of every text-mode command.
