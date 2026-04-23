# 🌐 trace-geo

Traceroute geográfico para terminal que clasifica cada salto de red según el tipo de enlace físico: fibra terrestre, cable oceánico, enlace satelital o salto internacional. Diseñado para ver de forma clara por dónde viajan tus paquetes cuando llegan a destinos en otros continentes.

```
╔══════════════════════════════════════════════════════════════════════╗
║          TRACEROUTE GEOGRÁFICO  →  210.212.39.138
╚══════════════════════════════════════════════════════════════════════╝

#    IP                ms       Latencia        Ciudad                País               Tipo de enlace
─────────────────────────────────────────────────────────────────────────────────────────────────────────
1    192.168.220.1     0ms      █░░░░░░░░░░░░  Red Local             –                 🏠 Red local
2    192.168.1.1       0ms      █░░░░░░░░░░░░  Red Local             –                 🏠 Red local
3    181.88.172.91     5ms      █░░░░░░░░░░░░  Buenos Aires          Argentina         🌍 Fibra terrestre
4    213.140.39.116    10ms     █░░░░░░░░░░░░  Madrid                Argentina         🌍 Fibra terrestre
     ⚠ IP de Spain (sede corporativa, router en Argentina)
  ────────────────  CRUCE OCEÁNICO  ────────────────
5    129.250.2.196     145ms    █████░░░░░░░  Miami                 United States      🌊 Cable oceánico
6    129.250.2.83      200ms    ████████░░░░  Los Angeles           United States      🌍 Fibra terrestre
  ────────────────  CRUCE OCEÁNICO  ────────────────
7    129.250.2.149     368ms    ████████████░  Chai Wan             Hong Kong          🌊 Cable oceánico

Resumen:
  🌊 Cruces oceánicos detectados : 2
  ✈  Países atravesados          : 3
  Destino final                  : India
```

## Características

- Clasifica cada salto en: red local, fibra terrestre, salto internacional, cable oceánico o enlace satelital
- Barra visual de latencia con colores (verde → amarillo → naranja → rojo)
- Separador gráfico explícito al detectar un cruce oceánico o satelital
- Detección de IPs mal geolocalizadas: operadoras multinacionales (Telefónica, NTT, Lumen, etc.) registran sus bloques de IPs en su país sede aunque los routers estén físicamente en otro continente. El script lo detecta y avisa
- Cache de consultas geo-IP en `/tmp/` para no repetir requests al mismo nodo
- Resumen final con conteo de cruces oceánicos y países atravesados

## Cómo funciona la clasificación

La fuente de verdad es la **latencia física**, no el country code de la IP.

La fibra óptica viaja a ~200.000 km/s. Eso implica que:

- Buenos Aires → Madrid ≈ 10.000 km → mínimo ~100 ms de delta solo de propagación
- Buenos Aires → Miami ≈ 7.000 km → mínimo ~70 ms

Si el delta entre dos hops es menor a 30 ms, es físicamente imposible que haya habido un cruce oceánico, sin importar lo que diga la geolocalización de la IP. Las reglas concretas son:

| Delta | Distancia geo | Resultado |
|---|---|---|
| < 30 ms | cualquiera | Fibra terrestre (o IP mal geolocalizada) |
| ≥ 60 ms | > 2.000 km | 🌊 Cable oceánico |
| ≥ 60 ms | < 2.000 km | ✈ Internacional |
| 30–59 ms | > 500 km + cambio de país | ✈ Internacional |
| > 500 ms (absoluto) | — | 🛰 Satelital |

## Requisitos

```bash
sudo apt install traceroute curl jq bc python3
```

Probado en Ubuntu 24.04. Debería funcionar en cualquier distro Debian-based sin cambios.

## Instalación

```bash
git clone https://github.com/tuusuario/trace-geo.git
cd trace-geo
chmod +x trace-geo.sh
```

## Uso

```bash
./trace-geo.sh google.com
./trace-geo.sh 8.8.8.8
./trace-geo.sh bbc.co.uk
```

El script necesita poder ejecutar `traceroute`, que en algunos sistemas requiere privilegios. Si no obtenés resultados, probá con `sudo`:

```bash
sudo ./trace-geo.sh google.com
```

## Limitaciones conocidas

- La geolocalización depende de [ip-api.com](http://ip-api.com), un servicio gratuito con límite de 45 requests por minuto. Para trazas largas o uso intensivo, los requests se cachean en `/tmp/` durante la sesión.
- Los hops que no responden (tiempo de espera, `* * *`) se omiten, lo que puede afectar el cálculo de deltas entre nodos consecutivos.
- En redes con enrutamiento ECMP (múltiples rutas de igual costo), los deltas de latencia pueden ser negativos o inconsistentes. El script usa valor absoluto del delta para mitigarlo.
- La detección satelital basada en latencia >500 ms puede dar falsos positivos en redes muy congestionadas.

## Licencia

MIT
