# ProxyCore - MITM Proxy Server

ProxyCore è un server proxy MITM (Man-in-the-Middle) scritto in Go che permette di intercettare e loggare traffico HTTP e HTTPS.

## Funzionalità

- Intercettazione HTTPS con generazione automatica di certificati
- Logging in tempo reale via WebSocket
- API REST per accesso ai log
- Forward trasparente delle richieste
- Supporto per proxy chain
- Pagina di benvenuto con download certificati

## Porte

- `:8080` - Proxy Server
- `:8081` - API Server (WebSocket e REST API)

## Endpoints

- `http://localhost:8081/welcome` - Pagina di benvenuto
- `http://localhost:8081/cert/ios` - Download certificato per iOS Simulator
- `http://localhost:8081/cert/macos` - Download certificato per MacOS
- `http://localhost:8081/logs` - GET per ottenere i log recenti
- `ws://localhost:8081/ws` - WebSocket per log in tempo reale

## Utilizzo

1. Avvia il server:
   ```bash
   go run main.go
   ```

2. Visita `http://localhost:8081/welcome` per scaricare e installare il certificato CA

3. Configura il proxy nel tuo sistema:
   - Host: localhost
   - Porta: 8080

4. Il proxy è pronto per intercettare il traffico!
