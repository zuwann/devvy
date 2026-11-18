# Devvy da riga di comando (guida / command line guide)

Per amministratori e attività pianificate: stesse funzioni della pagina web, ma senza aprire il browser.

## Prima di iniziare

- Serve un **prompt dei comandi o PowerShell avviato come amministratore**. La riga di comando non chiede mai l'elevazione da sola: se non sei amministratore stampa un errore ed esce con codice 5.
- Spostati nella cartella di Devvy: `cd /d C:\Percorso\devvy`
- La sintassi è sempre: `devvy.bat /cli <Azione> [opzioni]`
- Le liste con la virgola vanno tra virgolette: `-Parts "devices,drivers"`.
- Lingua, eccezioni e opzioni sono quelle salvate nelle impostazioni (`data\settings.json`), le stesse della pagina.
- Ogni esecuzione scrive un log in `data\logs\cli-<data>.txt`.

## Azioni

| Comando | Cosa fa | Cambia qualcosa? |
|---|---|---|
| `devvy.bat -h` (o `/?`, `/help`) | Mostra l'aiuto con tutti i comandi, anche senza essere amministratore | No |
| `devvy.bat /cli Audit` | Inventario e riepilogo: dispositivi fantasma, driver vecchi, abbinamenti Bluetooth vecchi, driver da controllare | No |
| `devvy.bat /cli Clean` | Anteprima della pulizia: cosa verrebbe rimosso | No |
| `devvy.bat /cli Clean -Apply` | Pulizia vera, ripetuta finché compaiono altri residui (massimo 3 giri in più), poi inventario finale | **Sì** |
| `devvy.bat /cli Search` | Cerca nel catalogo Microsoft driver più nuovi (serve il consenso al catalogo nelle impostazioni) | No |
| `devvy.bat /cli Update` | Controlla se esiste una versione nuova di Devvy su GitHub | No |
| `devvy.bat /cli Update -Apply` | Scarica, verifica (SHA-256) e installa la versione nuova | **Sì** (programma) |
| `devvy.bat /cli Profile -Export file.json` | Salva il profilo (eccezioni, opzioni, righe personali) | Scrive il file |
| `devvy.bat /cli Profile -Import file.json` | Aggiunge un profilo esportato: non cancella nulla di tuo | **Sì** (impostazioni) |

## Opzioni

| Opzione | Significato |
|---|---|
| `-Output text` / `-Output json` | Testo colorato (predefinito) oppure un solo oggetto JSON, adatto a script e strumenti |
| `-Apply` | Con `Clean` e `Update`: esegue davvero. Senza, mostra solo l'anteprima |
| `-Parts "devices,drivers,oldversions,bluetooth"` | Con `Clean`: cosa pulire (predefinito: tutto) |
| `-Backup none\|drivers\|full` | Con `Clean -Apply`: backup prima di cambiare (nessuno, solo driver, completo con punto di ripristino) |
| `-Import file.json` / `-Export file.json` | Con `Profile` |

## Codici di uscita

| Codice | Significato |
|---|---|
| 0 | Tutto a posto / fatto |
| 1 | Trovato qualcosa (Audit, anteprima Clean, Search con driver più nuovi, Update disponibile) |
| 2 | Errore (vedi il log) |
| 3 | Serve riavviare Windows |
| 4 | Non consentito (catalogo disattivato nelle impostazioni) |
| 5 | Non sei amministratore |

Il codice viene **stampato anche a fine comando** (riga "Codice di uscita N: ..."). Per leggerlo in uno script: da PowerShell `$LASTEXITCODE`, da cmd `echo %errorlevel%` (in PowerShell `%errorlevel%` NON funziona).

## Esempi

```
devvy.bat /cli Audit
devvy.bat /cli Audit -Output json > audit.json
devvy.bat /cli Clean -Parts "devices,bluetooth"
devvy.bat /cli Clean -Apply -Backup drivers
devvy.bat /cli Search
devvy.bat /cli Update
devvy.bat /cli Update -Apply
devvy.bat /cli Profile -Export "%USERPROFILE%\devvy-profile.json"
```

## Attività pianificata (controllo settimanale)

Da un prompt amministratore, una volta (adatta i percorsi):

```
schtasks /Create /TN "Devvy weekly audit" /SC WEEKLY /D MON /ST 09:00 /RL HIGHEST /TR "cmd /c \"C:\Tools\devvy\devvy.bat\" /cli Audit -Output json > \"C:\Tools\devvy-audit.json\""
```

Per controllare gli aggiornamenti del programma ogni settimana usa `Update` al posto di `Audit`.
Non pianificare `Clean -Apply` senza averlo provato prima a mano: rimuove davvero.

## Note

- All'avvio compare subito un messaggio di attesa; rimozioni, aggiornamenti e backup scrivono a schermo cosa fanno (anche nell'anteprima di `Clean`).
- Le domande che nella pagina compaiono come popup, qui non vengono mai fatte: lo script sceglie sempre la risposta prudente.
- `Update -Apply` sostituisce anche `devvy.bat` a fine lavoro: non serve riavviare nulla.
- Una cartella di rete va bene, ma il prompt amministratore non vede le unità mappate dell'utente normale: usa il percorso UNC (`\\server\cartella`).
- I nomi utente con caratteri speciali (come il punto esclamativo) sono supportati.

---

# English summary

Run from an **administrator** prompt: `devvy.bat /cli <Action> [options]`.

- `Audit` (read only) · `Clean` (preview; `-Apply` removes) · `Search` (catalog, needs consent) · `Update` (check; `-Apply` installs the newest release after SHA-256 checks) · `Profile -Export|-Import file.json`.
- Options: `-Output text|json`, `-Apply`, `-Parts "devices,drivers,oldversions,bluetooth"`, `-Backup none|drivers|full`.
- Exit codes: 0 ok, 1 findings / update available, 2 error, 3 restart needed, 4 not allowed, 5 not administrator.
- Log: `data\logs\cli-<date>.txt`. Quote comma lists. Questions are never asked: the cautious answer is used.
