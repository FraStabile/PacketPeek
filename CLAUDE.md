# PacketPeek

Proxy MITM per macOS per ispezionare e mockare traffico HTTP/HTTPS. Due livelli: app SwiftUI `ProxyApp` (target `PacketPeek`) e daemon Go `ProxyCore` (proxy :8080, API/WS 127.0.0.1:8081).

<!-- CLAUDE-WORKFLOW:START -->
## Comandi
- Stack: SwiftUI macOS (Xcode, scheme `ProxyApp`) + daemon Go 1.24 in `ProxyCore/`.
- Build Go: `cd ProxyCore && go build -o proxycore .`
- Test Go: `cd ProxyCore && go test ./...` (con `-race` se si tocca `proxy/proxy.go`)
- Vet Go: `cd ProxyCore && go vet ./...`
- Build app: `xcodebuild -scheme ProxyApp -configuration Debug build`
- Test app: `xcodebuild test -scheme ProxyApp -destination 'platform=macOS'`
- Lint Swift: `swiftlint`
- Versione: `MARKETING_VERSION` e `CURRENT_PROJECT_VERSION` in `ProxyApp.xcodeproj/project.pbxproj` (6 occorrenze ciascuno).

## Workflow di sviluppo (vincolante)
Vale per OGNI sessione e OGNI modifica al repository, anche minima. Uniche eccezioni: domande,
analisi senza modifiche, oppure richiesta esplicita dell'utente di procedere "senza workflow".

### Branch e worktree
- `main`: gestito solo dall'utente. Mai commit, push o merge su main.
- `develop`: branch di integrazione, modificato SOLO tramite PR mergiate.
- La cartella principale del repo resta su develop pulito: lì si fa solo `git pull`.
  Ogni task si sviluppa in un worktree dedicato:
  `git worktree add ../<nome-repo>-wt/<branch> -b <branch> origin/develop`
- Naming: `<tipo>/<issue>-<slug>`, con tipo tra fix, feat, ui, chore, refactor, test.
- Vietati `push --force` e `reset --hard` su branch condivisi.
- Mai committare segreti, file .env, catture di traffico reali o dati personali.
- `.claude/work/` è lo spazio di lavoro locale (stato, handoff, file temporanei): non si committa.

### Commit
Conventional Commits, piccoli e atomici, con riferimento alla issue: `fix(parser): gestisce chunked encoding (#42)`.

### Issue: ogni modifica è tracciata
- Ogni modifica parte da una issue. Se l'utente cita `#n` usa quella, altrimenti creala PRIMA di scrivere codice.
- Label (creale se mancano con `gh label create "<nome>" --color <hex> --force`):
  stati `status:todo` BFD4F2, `status:in-progress` FBCA04, `status:in-review` 5319E7,
  `status:changes-requested` D93F0B, `status:blocked` B60205, `status:done` 0E8A16;
  tipi `type:bug`, `type:feature`, `type:improvement`, `type:ui`, `type:chore`;
  priorità `prio:critical`, `prio:high`, `prio:medium`, `prio:low`.
- Body: contesto, problema (file:riga), proposta, criteri di accettazione `- [ ]`, branch, dipendenze (`Dipende da #n`).
- Testi lunghi in `.claude/work/tmp/` e passati con `--body-file`.
- Cambio stato: `gh issue edit <n> --remove-label "status:<vecchio>" --add-label "status:<nuovo>"`.
- Ogni commento inizia con `[<ruolo>] <data ora>` (es. `[implementer]`, `[pr-reviewer]`, `[orchestrator]`).

| Momento | Stato | Commento obbligatorio |
|---|---|---|
| Worktree creato, lavoro avviato | in-progress | branch, percorso worktree, approccio previsto |
| Scoperta rilevante | invariato | cosa è emerso, impatto, decisione presa |
| Build/test eseguiti | invariato | esito sintetico |
| PR aperta | in-review | link PR, riepilogo, come testare |
| Verdetto MODIFICHE | changes-requested | sintesi dei punti, link ai commenti |
| Modifiche risolte | in-review | correzioni punto per punto |
| Bloccato | blocked | causa, tentativi, cosa serve per sbloccare |
| Merge su develop | done | PR e commit di merge, follow-up aperti |

- Spunta i criteri di accettazione nel body man mano che sono soddisfatti.
- Problemi fuori scope: non allargare il task, apri una nuova issue con `Scoperta durante #<n>`.
- Le issue si chiudono da sole solo con merge sul branch di default: dopo il merge su develop chiudi
  esplicitamente con `gh issue close <n> --reason completed --comment "[...] Mergiata con PR #<pr>"`.

### Pull Request
- Prima di aprirla: `git fetch origin && git rebase origin/develop`; build, lint e test verdi.
  Se falliscono dopo 3 tentativi di correzione: issue in `status:blocked` con dettagli, e stop.
- `gh pr create --base develop`, body con cosa, perché, come testare e `Refs #<n>`.
- Una PR risolve una sola issue.

### Validazione e merge
- Ogni PR è validata dal subagente `pr-reviewer` (`.claude/agents/pr-reviewer.md`), mai da chi l'ha implementata.
- `VERDETTO: MODIFICHE` → correzioni nello stesso worktree, poi nuova validazione. Massimo 2 giri,
  poi `status:blocked` con spiegazione.
- `VERDETTO: OK` e check verdi → `gh pr merge <pr> --squash --delete-branch`, `git worktree remove <path>`,
  chiusura issue, `git pull` su develop nella cartella principale.
- A fine lavoro, riepilogo all'utente con link a issue e PR.

### Parallelismo
Task indipendenti che non toccano gli stessi file: worktree separati e subagenti in parallelo (max 4).
Ogni subagente lavora solo nel percorso assoluto del proprio worktree.

### Contesto e handoff
- All'avvio di ogni sessione, se esiste `.claude/work/HANDOFF.md` leggilo e riconcilia con
  `git worktree list`, `gh pr list --base develop` e `gh issue list --state open`, correggendo le discrepanze.
- Intorno al 40% di contesto usato, o a fine di un blocco di lavoro, scrivi `.claude/work/HANDOFF.md`:
  stato, issue/branch/worktree/PR in corso, decisioni e perché, prossimo passo come istruzione eseguibile.
  Commenta lo stato sulle issue in corso.
- Sessione interattiva: chiedi all'utente di eseguire `/clear` e poi scrivere "riprendi dall'handoff".
  Sessione automatica: termina.

## Linee guida UI
Strumento tecnico per sviluppatori: deve sembrare un inspector professionale, non una landing page.
Vietati: gradienti viola/blu decorativi, glassmorphism, ombre morbide ovunque, raggi enormi, emoji come icone,
card dentro card, copy promozionale, animazioni gratuite, palette da template, spaziature che riducono la densità.
Da fare: partire dal design system esistente personalizzando i componenti senza riscriverli; token di colori,
spaziature, raggi e font in un unico punto; alta densità leggibile e numeri tabulari; monospace per URL,
header, payload e JSON; colore solo con significato (status, metodi, errori) e contrasto AA in light e dark;
raggi 2–6px e bordi sottili al posto delle ombre; stati vuoto/caricamento/errore utili; scorciatoie da tastiera,
focus visibile, pannelli ridimensionabili; ogni PR di UI descrive il prima/dopo.
<!-- CLAUDE-WORKFLOW:END -->
