# Backlog v2.0.0

Fonte: audit v2 su develop 424cb27 (`audit-bugs.md`, `audit-improvements.md`, `audit-ui.md`). EPIC #2, milestone v2.0.0.

Ordine: critici, bug alti, migliorie, UI. Nessuna voce critica residua dopo l'integrazione di sprint1.

Nota: le voci I-13 e I-07 si basano su codice non letto per intero dall'audit (SidebarTreeBuilder, corpo di handleGetLogs): verificare prima di implementare.

## Task

| Issue | Task | Audit | Prio | File principali |
|---|---|---|---|---|
| #6 | Log con body grandi: alza maximumMessageSize del WebSocket | B-01 | high | ProxyApp/ProxyCore/ProxyCore.swift |
| #7 | Eventi senza perdite: seq monotono, /logs?since e backfill alla riconnessione | B-02, B-13, I-07 | high | ProxyCore/proxy/proxy.go, ProxyCore/api/server.go, ProxyApp/ProxyCore/ProxyCore.swift |
| #8 | Proxy di sistema: non lasciarlo acceso se osascript fallisce; pkill mirato | B-04 | high | ProxyApp/Utils/SystemProxyManager.swift, ProxyApp/ProxyCore/ProxyCore.swift |
| #9 | DecryptTraffic: passthrough TCP per gli host non selezionati | B-05 | high | ProxyCore/proxy/proxy.go, ProxyCore/proxy/monitored_apps.go |
| #10 | WebSocket/Upgrade e header hop-by-hop nel proxy | B-06, B-17 | high | ProxyCore/proxy/proxy.go |
| #11 | Deadline su tunnel HTTPS e ReadHeaderTimeout contro slowloris | B-07 | high | ProxyCore/proxy/proxy.go, ProxyCore/main.go |
| #12 | CA robusta: nessuna rigenerazione silenziosa, singleflight dei leaf, test cert/ | B-08, B-20 | medium | ProxyCore/cert/manager.go |
| #13 | Handshake TLS falliti visibili in UI | B-09 | medium | ProxyCore/proxy/proxy.go |
| #14 | Body capture: flag truncated, binari, decoder br/deflate | B-10 | medium | ProxyCore/proxy/body_capture.go, ProxyCore/proxy/proxy.go, ProxyApp/Model/ProxyLog.swift |
| #15 | Lifecycle daemon: PID file, killOldDaemon e removePID sicuri | B-11 | medium | ProxyCore/main.go, ProxyApp/ProxyCore/ProxyCore.swift |
| #16 | ProxyCore.swift: stato connessione corretto e decode WS fuori dal main actor | B-12, I-08 | medium | ProxyApp/ProxyCore/ProxyCore.swift |
| #17 | Budget in byte per il log del daemon e /logs paginato | B-14 | medium | ProxyCore/proxy/proxy.go, ProxyCore/api/server.go |
| #18 | Verifica TLS upstream di default con toggle nelle impostazioni | B-15 | medium | ProxyCore/proxy/proxy.go, ProxyApp/View/Settings |
| #19 | IPv6 e URL non ASCII: parsing corretto di clientIP e host | B-16 | low | ProxyApp/ViewModel/HomeViewModel.swift |
| #20 | API e mock: ?token= solo su /ws, regex invalida 400, AddMock persistente, host del match coerente | B-18, B-19 | low | ProxyCore/api/server.go, ProxyCore/proxy/mock_manager.go, ProxyCore/proxy/proxy.go |
| #21 | ExecutableInstaller: hash in background, errori propagati, copia atomica | B-21 | low | ProxyApp/Utils/ExecutableInstaller.swift |
| #22 | Mascheramento di Authorization, Cookie e Set-Cookie in UI ed export | I-04 | high | ProxyApp/Components/LogDetailView.swift, ProxyApp/ViewModel/HomeViewModel.swift |
| #23 | Header come liste ordinate nome/valore (Set-Cookie multipli fedeli) | I-05 | medium | ProxyCore/proxy/proxy.go, ProxyApp/Model/ProxyLog.swift |
| #24 | Copy as cURL ed Export HAR | I-06 | medium | ProxyApp/Components/LogTableView.swift, nuovo ProxyApp/Utils (funzioni pure) |
| #25 | Tabella log: filtri status/metodo, Pause/Clear, debounce, empty state, ordinamento, shortcut | I-03, U-05, U-11 (parziale) | high | ProxyApp/Components/LogTableView.swift, ProxyApp/ContentView.swift |
| #26 | Memoria e performance lato Swift: ring buffer, store con indici, niente doppioni | B-03, I-01, I-02 | high | ProxyApp/ProxyCore/ProxyCore.swift, ProxyApp/ViewModel/HomeViewModel.swift |
| #27 | Test infra: TEST_HOST, CI GitHub Actions, .swiftlint.yml, primi test Swift | B-22, I-10 | medium | ProxyApp.xcodeproj/project.pbxproj, .github/workflows, .swiftlint.yml, ProxyApp/ProxyAppTests |
| #28 | Log del daemon: oscurare la query string degli URL | I-11 | medium | ProxyCore/proxy/proxy.go |
| #29 | Pulizia: codice morto, print -> os.Logger, import duplicati, copiedKey | I-09, U-06, U-16 (parziale), U-20 (parziale) | low | ProxyApp/ViewModel/HomeViewModel.swift, ProxyApp/Components/LogTableView.swift, ProxyApp/Components/LogDetailView.swift, ProxyApp/ContentView.swift |
| #30 | Sidebar: aggiornamento incrementale invece di ricostruire l'albero ogni 250 ms | I-13 | low | ProxyApp/Sidebar/SidebarTreeView.swift, ProxyApp/ViewModel/HomeViewModel.swift |
| #31 | Igiene repo e CA nella storia git | I-15, I-12 | low | AGENTS.md, default.profraw, storia git |
| #32 | Dialog mock: un solo editor, copy EN, token di design, validazione JSON | U-01, U-02, U-03 | high | ProxyApp/View/MockEditView.swift, ProxyApp/View/MockModalEditView.swift |
| #33 | Mock Manager: stati vuoto/caricamento/errore con retry, badge e mono | U-04 | high | ProxyApp/View/MockManagerView.swift |
| #34 | DesignSystem: scala raggi 2/4/6, colori AA light/dark, tipografia mono | U-07, U-08, U-09 | medium | ProxyApp/DesignSystem/DesignSystem.swift, ProxyApp/Components/ProxyStatusPill.swift, ProxyApp/ContentView.swift, ProxyApp/View/Settings/MainSettingView.swift |
| #35 | Banner stoppedIdle/failed con azione Restart/Retry e pill accessibile | U-10, U-12 | medium | ProxyApp/ContentView.swift, ProxyApp/Components/ProxyStatusPill.swift |
| #36 | Dettaglio log: tab accessibili, CopyButton, stati body, cache JSON | U-14, U-15, U-16, I-14 | medium | ProxyApp/Components/LogDetailView.swift |
| #37 | Layout: persistere il divisore, stato reale degli step del welcome | U-13, U-20 | low | ProxyApp/ContentView.swift |
| #38 | Sidebar row, AddAppSheet e Settings: a11y, shortcut, stati | U-17, U-18, U-19 | low | ProxyApp/Sidebar/SidebarRow.swift, ProxyApp/View/AddAppSheet.swift, ProxyApp/View/Settings/MainSettingView.swift |

## Ondate (max 4 in parallelo, nessun file in comune nella stessa ondata)

`ProxyCore/proxy/proxy.go` e `ProxyApp/ProxyCore/ProxyCore.swift` sono i file piu contesi: i task che li toccano sono serializzati (una sola issue per ondata su proxy.go).

Corsia proxy.go in ordine: T06 (#11), T05 (#10), T04 (#9), T02 (#7), T09 (#14), T12 (#17), T18 (#23), T13 (#18), T15 (#20), T08 (#13), T23 (#28).

Verificare a ogni ondata che i file dichiarati non siano cambiati da PR gia mergiate.

### Ondata 1 (fondamenta)
- #27 Test infra: TEST_HOST, CI GitHub Actions, .swiftlint.yml, primi test Swift
- #6 Log con body grandi: alza maximumMessageSize del WebSocket
- #11 Deadline su tunnel HTTPS e ReadHeaderTimeout contro slowloris
- #12 CA robusta: nessuna rigenerazione silenziosa, singleflight dei leaf, test cert/

### Ondata 2
- #10 WebSocket/Upgrade e header hop-by-hop nel proxy
- #8 Proxy di sistema: non lasciarlo acceso se osascript fallisce; pkill mirato
- #22 Mascheramento di Authorization, Cookie e Set-Cookie in UI ed export
- #32 Dialog mock: un solo editor, copy EN, token di design, validazione JSON

### Ondata 3
- #9 DecryptTraffic: passthrough TCP per gli host non selezionati
- #26 Memoria e performance lato Swift: ring buffer, store con indici, niente doppioni
- #34 DesignSystem: scala raggi 2/4/6, colori AA light/dark, tipografia mono
- #33 Mock Manager: stati vuoto/caricamento/errore con retry, badge e mono

### Ondata 4
- #7 Eventi senza perdite: seq monotono, /logs?since e backfill alla riconnessione
- #25 Tabella log: filtri status/metodo, Pause/Clear, debounce, empty state, ordinamento, shortcut
- #36 Dettaglio log: tab accessibili, CopyButton, stati body, cache JSON
- #21 ExecutableInstaller: hash in background, errori propagati, copia atomica

### Ondata 5
- #14 Body capture: flag truncated, binari, decoder br/deflate
- #35 Banner stoppedIdle/failed con azione Restart/Retry e pill accessibile
- #15 Lifecycle daemon: PID file, killOldDaemon e removePID sicuri
- #19 IPv6 e URL non ASCII: parsing corretto di clientIP e host

### Ondata 6
- #17 Budget in byte per il log del daemon e /logs paginato
- #29 Pulizia: codice morto, print -> os.Logger, import duplicati, copiedKey
- #37 Layout: persistere il divisore, stato reale degli step del welcome
- #38 Sidebar row, AddAppSheet e Settings: a11y, shortcut, stati

### Ondata 7
- #23 Header come liste ordinate nome/valore (Set-Cookie multipli fedeli)
- #30 Sidebar: aggiornamento incrementale invece di ricostruire l'albero ogni 250 ms
- #31 Igiene repo e CA nella storia git

### Ondata 8
- #18 Verifica TLS upstream di default con toggle nelle impostazioni
- #24 Copy as cURL ed Export HAR

### Ondata 9
- #20 API e mock: ?token= solo su /ws, regex invalida 400, AddMock persistente, host del match coerente

### Ondata 10
- #13 Handshake TLS falliti visibili in UI

### Ondata 11
- #28 Log del daemon: oscurare la query string degli URL

## Fuori roadmap / decisioni del proprietario

- #31: la rimozione di AGENTS.md e la gestione della CA nella storia git richiedono una decisione del proprietario.
- Permessi: il push dei branch funziona; la cancellazione forzata dei branch locali e bloccata da un hook del proprietario.
