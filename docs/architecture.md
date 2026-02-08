# Architecture: API Proxy & Network Isolation

## How the Reverse Proxy Works

The API proxy is a lightweight nginx container that sits between the OpenClaw containers and the upstream LLM APIs. It is the **only** component that holds real API keys. OpenClaw containers never see them.

### Request Flow

```mermaid
sequenceDiagram
    participant OC1 as openclaw-1
    participant Proxy as api-proxy (nginx)
    participant API as api.anthropic.com

    OC1->>Proxy: POST /anthropic/v1/messages<br/>x-api-key: proxy
    Note over Proxy: Strips dummy key<br/>Injects real ANTHROPIC_API_KEY
    Proxy->>API: POST /v1/messages<br/>x-api-key: sk-ant-***
    API-->>Proxy: 200 OK (streamed response)
    Proxy-->>OC1: 200 OK (streamed response)
```

### Network Topology

Each OpenClaw container is placed on its own isolated Docker bridge network. The proxy bridges all networks so it can serve every container, but the containers cannot reach each other.

```mermaid
graph TB
    subgraph Internet
        ANTH[api.anthropic.com]
        OAI[api.openai.com]
        WEB[Public Internet]
    end

    subgraph "net-oc1 (bridge)"
        OC1[openclaw-1<br/><i>ANTHROPIC_API_KEY=proxy</i>]
        P1[api-proxy<br/><i>Real keys inside</i>]
    end

    subgraph "net-oc2 (bridge)"
        OC2[openclaw-2<br/><i>ANTHROPIC_API_KEY=proxy</i>]
        P2[api-proxy]
    end

    OC1 -->|"HTTP :18080"| P1
    OC2 -->|"HTTP :18080"| P2
    P1 -->|"HTTPS + real key"| ANTH
    P1 -->|"HTTPS + real key"| OAI
    OC1 -->|"direct"| WEB
    OC2 -->|"direct"| WEB
    OC1 -.-x|"blocked"| OC2

    style P1 fill:#2d6a4f,color:#fff
    style P2 fill:#2d6a4f,color:#fff
    style OC1 fill:#1b4332,color:#fff
    style OC2 fill:#1b4332,color:#fff
    style ANTH fill:#264653,color:#fff
    style OAI fill:#264653,color:#fff
    style WEB fill:#264653,color:#fff
```

> `api-proxy` appears twice in the diagram because it is a single container connected to **both** networks simultaneously. Docker allows this — the container gets one virtual interface per network.

### What the Proxy Does

1. **Receives** an HTTP request from an OpenClaw container on port 18080
2. **Routes** based on path prefix:
   - `/anthropic/*` → `https://api.anthropic.com/*`
   - `/openai/*` → `https://api.openai.com/*`
   - Everything else → connection dropped (HTTP 444)
3. **Replaces** the authentication header with the real API key
4. **Forwards** the request upstream over HTTPS
5. **Streams** the response back without buffering (important for SSE/streaming completions)

### Why the Key Can't Be Stolen

| Attack Vector | Why It Fails |
|---|---|
| Read env vars from inside OpenClaw container | Container only has `ANTHROPIC_API_KEY=proxy` — a dummy value |
| Redirect proxy to send key to attacker server | Upstream hosts are hardcoded in nginx config (`api.anthropic.com`, `api.openai.com`) |
| Access proxy container's environment | Containers are on different Docker namespaces; no shared filesystem or Docker socket |
| Inspect proxy via Docker API | Docker socket is not mounted into any container |
| Read key from proxy's filesystem | Proxy runs with `read_only: true`; config is baked into the image at build time and key is only in memory via envsubst |
| Man-in-the-middle the proxy | `NET_RAW` capability is dropped everywhere; ARP spoofing is not possible |

### Adding More Containers

When you run `./manage.sh add 3`, the script:

1. Creates a new bridge network `openclaw-containers_net-oc3`
2. Connects `api-proxy` to that network
3. Starts `openclaw-3` on that network with dummy credentials pointing at the proxy

The new container is automatically isolated from all other OpenClaw containers.

```mermaid
graph LR
    subgraph "net-oc1"
        OC1[openclaw-1]
    end
    subgraph "net-oc2"
        OC2[openclaw-2]
    end
    subgraph "net-oc3"
        OC3[openclaw-3]
    end

    PROXY((api-proxy))

    OC1 --> PROXY
    OC2 --> PROXY
    OC3 --> PROXY
    OC1 -.-x OC2
    OC1 -.-x OC3
    OC2 -.-x OC3

    style PROXY fill:#2d6a4f,color:#fff
    style OC1 fill:#1b4332,color:#fff
    style OC2 fill:#1b4332,color:#fff
    style OC3 fill:#1b4332,color:#fff
```
