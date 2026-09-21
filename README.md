# OpenShift Gateway API HTTP Echo + CORS

Demo of an HTTP echo service exposed through **Kubernetes Gateway API** on OpenShift, with **CORS** handled at the gateway layer—including OPTIONS preflight answered locally (HTTP **204**, no backend hop).

## Architecture

```
Client
  │  HTTPS
  ▼
OpenShift Route (edge TLS)          manifests/03-route.yaml
  │  HTTP
  ▼
Gateway API Gateway (Istio/Envoy)   manifests/01-gateway.yaml
  │
  ├─ OPTIONS ──► Envoy direct_response 204 + CORS headers
  │              (EnvoyFilter)          manifests/04-cors-preflight-envoyfilter.yaml
  │
  └─ GET/POST/… ► HTTPRoute
                  ResponseHeaderModifier (CORS on responses)
                  → Service → echo Deployment
                  manifests/02-echo.yaml
```

| Resource | Role |
|---|---|
| `GatewayClass` `openshift-default` | Enables OpenShift’s Gateway API controller (lightweight Istio in `openshift-ingress`) |
| `Gateway` `echo-gateway` | Shared HTTP/HTTPS listeners for `*.gwapi.<apps-domain>` |
| `HTTPRoute` `http-echo` | Routes non-OPTIONS methods to the echo Service; sets CORS response headers |
| `EnvoyFilter` `echo-cors-preflight` | Short-circuits OPTIONS with `direct_response` status 204 |
| OpenShift `Route` | Publishes the hostname when the Gateway Service has no external LoadBalancer |

Public URL (this workshop cluster):

`https://echo.gwapi.apps.cluster-k5msd.dyn.redhatworkshops.io/`

## Requirements

- **OpenShift 4.19+** (validated on **4.21**) with cluster-admin (or equivalent) to:
  - create `GatewayClass` / resources in `openshift-ingress`
  - create `EnvoyFilter` objects
- **OpenShift Gateway API** via Ingress Operator:
  - `GatewayClass` with `controllerName: openshift.io/gateway-controller/v1`
  - installs istiod / gateway dataplane in `openshift-ingress`
- **`oc` / `kubectl`** and network access to the cluster API and apps domain
- **TLS secret** referenced by the Gateway HTTPS listener (here: `cert-manager-ingress-cert` in `openshift-ingress`)
- On platforms **without** a cloud LoadBalancer (e.g. workshop / `platform: None`), an **OpenShift Route** (or equivalent) to front the Gateway Service

### Tools

- `oc` (or `kubectl`)
- `curl` and `bash` for `scripts/test-echo-cors.sh`

## Deploy

```bash
oc apply -f manifests/00-gatewayclass.yaml
# wait until GatewayClass shows Accepted + ControllerInstalled
oc apply -f manifests/01-gateway.yaml
oc apply -f manifests/02-echo.yaml
oc apply -f manifests/03-route.yaml
oc apply -f manifests/04-cors-preflight-envoyfilter.yaml
```

Adapt hostnames in `01-gateway.yaml`, `02-echo.yaml`, `03-route.yaml`, and the EnvoyFilter vhost names in `04-cors-preflight-envoyfilter.yaml` to your cluster’s apps domain.

## CORS behaviour

| Request | Where handled | Result |
|---|---|---|
| `OPTIONS` (preflight) | EnvoyFilter `HTTP_ROUTE` + `direct_response` | **204**, CORS headers, **empty body**, backend not called |
| Other methods (`GET`, `POST`, …) | HTTPRoute → echo Service | **200** (echo JSON) + CORS headers via `ResponseHeaderModifier` |

CORS header values (allow-origin `*`, methods, headers, max-age) are duplicated in the HTTPRoute filter and the EnvoyFilter so preflight and actual responses stay aligned.

## Test

```bash
./scripts/test-echo-cors.sh
```

Optional overrides: `HOST`, `BASE_URL`, `ORIGIN`, `NS`.

The script checks HTTP status, CORS headers, empty OPTIONS body, and that no new `"method":"OPTIONS"` lines appear in the echo pod logs.

## Limitations

1. **No native Gateway API CORS / DirectResponse on this stack**  
   OpenShift’s managed `HTTPRoute` CRD only allows filters: `RequestHeaderModifier`, `ResponseHeaderModifier`, `RequestMirror`, `RequestRedirect`, `URLRewrite`, `ExtensionRef`.  
   `type: CORS` and DirectResponse are **rejected** by the API.  
   Envoy Gateway’s `SecurityPolicy.spec.cors` (`gateway.envoyproxy.io`) is **not** installed and is **not** understood by the OpenShift/Istio Gateway controller (even though the dataplane is Envoy).

2. **EnvoyFilter is Istio/OpenShift-specific**  
   Preflight short-circuit depends on Istio `EnvoyFilter` and exact Envoy **vhost** names (`<hostname>:80` / `:443`). Renaming the Gateway, hostname, or listeners requires updating the filter. This is not portable to Contour, nginx-gateway-fabric, or Envoy Gateway without rework.

3. **`allowedRoutes.namespaces.from: All` on the shared Gateway**  
   Convenient for a demo; in production prefer a namespace selector (e.g. `shared-gateway-access`) to avoid hostname hijacking across tenants ([OpenShift Gateway API docs](https://docs.okd.io/latest/networking/ingress_load_balancing/configuring_gateway_api/enable-gateway-api.html)).

4. **External exposure may need a Route**  
   The Gateway Service is `LoadBalancer`. On clusters without a LB provider it stays `<pending>`; this demo uses an OpenShift Route for reachability. Gateway `Programmed` may remain `False` for address assignment even while traffic works via the Route.

5. **CORS policy is static**  
   Allow-origin is `*` (no credentials). Reflecting `Origin`, credentialed CORS, or per-route policies need filter/HTTPRoute changes (or a different Gateway implementation with a first-class CORS API).

6. **Echo listens on 8080**  
   OpenShift `restricted-v2` SCC blocks binding to port 80 in the container; the Service/HTTPRoute use 8080.

7. **OSSM v2 conflict**  
   Enabling Gateway API installs OSSM/Istio **v3-style** components in `openshift-ingress`. An existing **OSSM v2** subscription can conflict and degrade the ingress operator.

## Layout

```
manifests/
  00-gatewayclass.yaml
  01-gateway.yaml
  02-echo.yaml              # Namespace, Deployment, Service, HTTPRoute
  03-route.yaml             # OpenShift Route → gateway Service
  04-cors-preflight-envoyfilter.yaml
scripts/
  test-echo-cors.sh
```
