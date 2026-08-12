<div align="center">

<img src="docs/icon.png" width="128" alt="Icono de T3Notch">

# T3Notch

**Tus agentes, bajo el notch.**

Un notch dinámico de estilo Alcove para [T3 Code](https://github.com/pingdotgg/t3code): progreso en vivo de los agentes, la lista de tareas y aprobaciones a las que puedes responder sin cambiar de ventana.

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-1d1d1f?logo=apple&logoColor=white)
![Swift 6.3](https://img.shields.io/badge/Swift-6.3-F05138?logo=swift&logoColor=white)
![SwiftUI + AppKit](https://img.shields.io/badge/SwiftUI-AppKit-3562f5)

</div>

![El notch mientras un agente trabaja](docs/notch.png)

T3Notch se sitúa donde ya está el notch de tu Mac y responde a la pregunta que sigues comprobando con alt-tab: ¿qué está haciendo el agente ahora mismo? Se mantiene como un pequeño indicador mientras el trabajo avanza, se expande cuando lo señalas y se abre cuando un agente necesita una respuesta.

> [!NOTE]
> T3Notch es un proyecto independiente y no está afiliado a T3 o T3 Code, ni respaldado o patrocinado por ellos.

![El indicador contraído](docs/pill.png)

## Características destacadas

- **El logotipo y modelo del propio proveedor**, la máquina en la que se ejecuta el trabajo, la rama y cuánto tiempo lleva la ejecución actual en curso.
- **Un feed de actividad** de las últimas cosas que ha hecho el agente: los comandos que ha ejecutado y los archivos que ha modificado, todo lo que aún está en curso se muestra en color.
- **La lista de tareas** del plan del agente, con una animación de marca de verificación cuando los pasos se completan.
- **Aprobaciones y preguntas respondidas en su lugar**, una diapositiva a la vez.
- **Una tarjeta por agente** cuando varios están funcionando, agrupados por máquina y proyecto.
- **Máquinas locales y remotas juntas**, con emparejamiento directo LAN/Tailscale/HTTPS y una importación opcional de compatibilidad con T3 Connect.
- **Los agentes finalizados permanecen fijados** hasta que realmente los has revisado.
- **Los hitos tienen un momento**: un banner cuando un plan se completa, confeti cuando una rama se mergea.
- **Un panel de control** para la atención, las animaciones, el número de filas y en qué pantalla se encuentra.
- **Se actualiza automáticamente** desde las versiones de GitHub, con un canal de pre-lanzamiento para versiones que no están listas para todos.

## Un vistazo alrededor

### Varios agentes al mismo tiempo

Cada agente en ejecución tiene una tarjeta presionable, agrupada bajo su proyecto, y el panel se expande para acomodarlos. Seleccionar una tarjeta cambia el detalle que se muestra debajo de ella.

![Tarjetas para tres agentes agrupados por proyecto](docs/agents.png)

### Preguntas, una a la vez

Las aprobaciones y preguntas de T3 Code aparecen como un carrusel: responde una y se desliza a la siguiente, para que un lote de preguntas no se convierta en un muro de texto. El panel se abre automáticamente y se resalta en naranja cuando hay algo pendiente.

![Una pregunta pendiente con dos opciones](docs/question.png)

### Cuando algo se completa

Finalizar un paso de un plan hace que su marca de verificación rebote y envía un anillo desde ella. Finalizar todo el plan, o mergear una rama, hace que un banner entre en el panel y lo mantenga abierto durante unos segundos: porque estos momentos llegan exactamente cuando nadie está señalando.

![El banner de merge con confeti](docs/merged.png)

### Panel de control

### Primer lanzamiento

La primera ejecución es un breve tour, y el notch lo realiza en lugar de ser descrito en abstracto. Un agente falso se mueve sobre la ventana y trabaja en un plan mientras lees, para que cada afirmación en la pantalla sea visible unos centímetros más arriba.

Luego pregunta una pregunta, en el notch, y espera: responderla allí es como avanza el tour, y una segunda pregunta se desliza detrás de la primera para mostrar la cola. Su plan termina con un banner, otros dos agentes falsos se mueven detrás de él: uno en otro proyecto, uno que necesita una respuesta; y presionar cualquiera de sus tarjetas cambia el panel a ese agente, lo cual es todo el truco de ejecutar varios al mismo tiempo.

El tour termina con una prueba de conexión que no es falsa: cada paso hace la solicitud que describe, y los fallos imprimen lo que regresó junto con el comando para solucionarlo.

Nada en el tour toca a tus agentes reales: el sondeo se suspende mientras la ventana esté abierta, y los agentes falsos se descartan cuando se cierra. Están marcados con una pequeña etiqueta **Demo** junto al reloj del notch, que es la única diferencia entre el panel del tour y el real. Puedes reproducirlo en cualquier momento desde **Ajustes → Inicio rápido**.

## Instalación

Requiere macOS 26+, Xcode 26.6+ y una ejecución de T3 Code con su servidor local en `127.0.0.1:3773`.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./Scripts/bundle.sh
open dist/T3Notch.app
```

`xcode-select` puede apuntar a las Herramientas de Command Line, que no pueden construir un bundle de aplicación SwiftUI: fija `DEVELOPER_DIR` como se indica arriba.

Para un token, T3Notch lo intenta en el Keychain, luego `t3 auth session issue --token-only`, luego `npx -y t3@latest auth session issue --token-only`. Si los tres fallan, puedes pegar un token de portador en el panel. Los tokens viven en el Keychain bajo `gg.t3tools.t3notch`, y un token guardado se descarta si la versión que lo escribió no es la versión que lo lee: de lo contrario, cada actualización abriría el prompt de contraseña del Keychain, lo que cuesta más que generar un token nuevo.

Ese comportamiento de cambio de firma se aplica solo al token local auto-renovable. Las credenciales remotas usan un vault de Keychain separado y versionado y sobreviven a actualizaciones de la app. T3Notch te pide que desbloquees ese vault si macOS requiere acceso de nuevo; nunca elimina una sesión remota solo porque la app cambió de firma.

## Máquinas remotas

T3Notch puede monitorear los entornos de T3 Code en un Mac mini, otro MacBook o cualquier servidor remoto compatible. Esto es monitoreo y respuesta de agentes, no compartición de pantalla, un terminal remoto o control general del escritorio. El notch puede:

- mostrar agentes locales y remotos al mismo tiempo;
- responder aprobaciones y preguntas de usuarios en la máquina donde se originaron;
- interrumpir el turno actual;
- hacer deep-link al hilo remoto de T3 Code correspondiente.

No inicia agentes, gestiona proyectos, inspecciona worktrees remotos o expone archivos remotos. La observación de merges permanece local en esta Mac.

### Emparejamiento directo

En la máquina que ejecuta T3 Code, abre **Ajustes → Conexiones**, habilita el acceso de red y crea un enlace de emparejamiento. Para un Mac mini sin pantalla, `npx t3 serve` imprime el mismo enlace. En el Mac que ejecuta T3Notch:

1. Abre **T3Notch → Ajustes → Máquinas**.
2. Elige **Añadir…** y pega el enlace completo de emparejamiento.
3. Alternativamente, usa el campo avanzado de URL de backend y código de emparejamiento.

HTTPS o una Tailnet privada es recomendado. HTTP plano es aceptado para loopback; un endpoint HTTP no-loopback requiere un reconocimiento separado y persistente.
T3Notch lee el descriptor del entorno antes de consumir el código de una sola vez, lo intercambia por una sesión vinculada a DPoP con solo `orchestration:read orchestration:operate`, verifica esa sesión y olvida inmediatamente el código de emparejamiento. Tokens y fragmentos de URL nunca están incluidos en un enlace de hilo abierto.

Consulta la guía de Acceso Remoto de T3 Code: [Remote Access guide](https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md) para configuración LAN, Tailscale y HTTPS.

### Importación de compatibilidad con T3 Connect

Las versiones de lanzamiento integran la misma configuración pública de Clerk y relay que T3 Code. **Importar T3 Connect…** está habilitado cuando T3 Code tiene una sesión firmada segura y reconocida en `~/.t3/userdata/clerk-tokens.json`. La detección verifica propiedad, permisos, tipo de archivo y esquema sin descifrar nada ni tocar el Keychain. Un archivo inseguro produce una fila de Máquinas explicativa con un comando copiable para arreglar permisos; T3Notch no modifica el archivo de T3 Code en sí.
Antes de copiar ese comando o importar una sesión, T3Notch requiere confirmación de que el Mac es privado y confiable. No uses esta importación de compatibilidad en un Mac público, compartido, prestado u otro no confiable: `chmod 600` limita el acceso a la cuenta actual de macOS, pero no puede hacer que una cuenta compartida sea segura.

La importación es explícita. macOS puede pedir una vez por acceso a la clave de Almacenamiento Seguro Electrón de T3 Code; T3Notch copia la credencial activa del cliente Clerk en su propio Keychain y nunca modifica el archivo, ítem del Keychain, cuenta o entornos vinculados de T3 Code. Se apoya el almacenamiento de T3 Code en producción/nightly; el almacenamiento del canal dev está intencionalmente no soportado.

T3 Connect es un adaptador de compatibilidad sobre los contratos actuales de Clerk, relay y Electron de upstream. Si T3 Code rota su sesión cifrada, Ajustes reporta que una nueva sesión está disponible y la reimportación sigue siendo un clic. Si T3 Code cierra sesión o Clerk rechaza la copia, T3Notch purga solo su copia importada y te pide que importes de nuevo. El monitoreo directo y local continúa independientemente.

Las construcciones de origen usan los valores públicos de producción por defecto y pueden sobrescribir los tres juntos para otro despliegue:

```bash
export T3CODE_CLERK_PUBLISHABLE_KEY=...
export T3CODE_CLERK_JWT_TEMPLATE=t3-relay
export T3CODE_RELAY_URL=https://relay.example.com
./Scripts/bundle.sh release
```

No se acepta ni se incrusta ninguna clave secreta de Clerk. Consulta la guía de configuración de T3 Connect de T3 Code: [Connect configuration guide](https://github.com/pingdotgg/t3code/blob/main/docs/cloud/t3-connect-clerk.md).

### Comportamiento de conexión

Cada máquina habilitada permanece conectada concurrentemente. El descubrimiento local es independiente y permanece usable a través de fallos remotos. Los shells activos hacen sondeo cada 800 ms; los shells locales y remotos inactivos hacen back-off a 3 y 5 segundos respectivamente. Los fallos usan retardo exponencial con jitter desde 500 ms a 30 segundos, con reintento inmediato en despertar, restauración de red y reconexión manual.

Cuando el acceso directo y el acceso T3 Connect reportan el mismo ID de entorno estable, aparecen como una máquina lógica. T3Notch prefiere loopback, luego un endpoint directo guardado, cae en Connect después de fallos directos repetidos o expiración de credenciales, sonda directo cada 60 segundos y cambia de vuelta después de dos sondas exitosas.

Los perfiles remotos en `UserDefaults` contienen solo etiquetas, URLs de endpoints, estado de habilitación y el reconocimiento de HTTP inseguro. Los tokens de acceso, credenciales Clerk importadas, tokens de relay y la clave P-256 con alcance de app viven en el vault de Keychain `gg.t3tools.t3notch`. Los diagnósticos excluyen deliberadamente cabeceras de autorización, pruebas DPoP, credenciales de emparejamiento, tokens Clerk, cuerpos de credenciales OAuth y claves privadas.

## Ajustes

**Ajustes…** en el ítem de la barra de menú (⌘,) abre el panel de control: tarjetas oscuras y redondeadas con un interruptor hecho a mano, porque una ventana de ajustes estándar de macOS no se parece en nada a la cosa que configura. Cada interruptor está conectado a un comportamiento que realmente lo lee: no hay preferencias decorativas.

| Ajuste | Qué lo lee |
| --- | --- |
| Abrir en preguntas | la rama de atención en `updatePresentation` |
| Reproducir un sonido | `playAttentionSound` |
| Mantener agentes finalizados fijados | `awaitsReview`, que es lo que fija una tarjeta Hecho |
| Celebrar tareas y merges | `celebrate`, y descarta cualquier cosa en la pantalla |
| Confeti en merges | el `ConfettiOverlay` en el panel expandido |
| Observar ramas para merges | el temporizador de 15s de merge |
| Preguntar a GitHub sobre pull requests | el forge de `MergeWatcher`: `.gh` o `.disabled` |
| Filas de actividad | `deriveRecentActivity(limit:)` |
| Filas de tareas | el límite de filas de la lista de tareas y su "+N más" |
| Pantalla | `NotchGeometry.preferredScreen(named:)` |
| Iniciar al login | `SMAppService.mainApp` |
| Abrir en la app de T3 Code | `openInT3Code`, antes de su fallback al navegador |
| Verificar automáticamente | el pollero de `Updater` |
| Descargar en segundo plano | si una versión encontrada se descarga sin preguntar |
| Incluir pre-lanzamientos | `UpdateChannel`, que ofrece los lanzamientos del feed |

Los valores viven en una sola estructura persistida en `UserDefaults`, y las escrituras van a través de un único setter que guarda y luego llama a `AgentStore.applySettings()`, así un interruptor volteado toma efecto inmediatamente en lugar de en el siguiente sondeo. Cambiar el ajuste del forge reconstruye `MergeWatcher`, que deliberadamente olvida lo que había visto: el nuevo vigilante solo reporta merges desde ese momento.

Dos ajustes dicen la verdad en lugar de pretender. Iniciar al login reporta lo que `SMAppService` realmente hizo: esta app está firmada de manera ad-hoc, así que el registro puede fallar, y la fila muestra el error y ofrece abrir Ítems de Login en su lugar en lugar de dejar un interruptor que parece activado y no hace nada. El selector de pantalla cae en la pantalla con notch integrada cada vez que la pantalla elegida está desconectada.

La sección de Hitos tiene botones de **Vista previa** para ambas animaciones, que es la única manera de verlas sin finalizar un plan o mergear una rama.

## Actualización

T3Notch se mantiene actualizado como lo hace T3 Code: una verificación poco después del inicio, luego una cada cierto tiempo; y reporta los mismos estados en el proceso: verificando, al día, disponible, descargando, listo para instalar. La tarjeta de **Actualizaciones** en el panel de control es donde todo eso se muestra, y el ítem de la barra de menú añade una entrada de **Instalar… y relanzar** una vez que una versión está esperando.

Nada reinicia la app detrás de tu espalda. Una nueva versión se descarga automáticamente si dejas eso encendido, pero instalarla siempre espera un clic.

```
Actualizaciones
  T3Notch 1.0.0 (1)          [ Qué hay de nuevo ]  [ Instalar y relanzar ]
  La versión 1.1.0 está lista para instalar.
```

| Ajuste | Valor por defecto | Efecto |
| --- | --- | --- |
| Verificar automáticamente | activado | 15s después del inicio, luego cada 6 horas |
| Descargar en segundo plano | activado | descargar tan pronto como una versión aparece |
| Incluir pre-lanzamientos | desactivado | también tomar versiones marcadas como pre-lanzamiento |

## Cómo funciona

- **T3NotchCore** — modelos, autorización DPoP, clientes de emparejamiento y Connect, sondeo por máquina, coordinación multi-entorno y derivaciones. Sin UI, y la única parte que está bajo prueba.
- **T3Notch** — el panel de AppKit y las vistas de SwiftUI.

Una sesión por entorno habilitado hace sondeo a `/api/orchestration/shell` y `/api/orchestration/threads/:id` de manera adaptativa. Los IDs compuestos de entorno/hilo mantienen iguales los IDs locales del servidor de no colisionar, y el despacho siempre es enrutado de vuelta al entorno que originó.
Un transporte WebSocket Effect-RPC puede reemplazar `PollingTransport` más adelante detrás del mismo protocolo `T3Transport`.

Los logotipos de proveedor son los mismos vectores que usa la app web de T3 Code (`apps/web/src/components/Icons.tsx`), analizados en runtime por `SVGPath.swift`, para que se mantengan fieles al píxel sin empaquetar activos de imagen. El nombre de máquina, OS y arquitectura vienen de `/.well-known/t3/environment`.

### Streams de detalle

El detalle del hilo — actividad, tareas, contexto, prompts pendientes — viaja en un `AsyncStream` de larga duración por cada hilo enfocado. `threadDetail(_:)` entrega un stream *nuevo* y termina el anterior, así solo debe ser llamado cuando el foco realmente cambia: `setFocusedThread` deliberadamente no lo llama, y `subscribeDetail` ignora solicitudes para el hilo que ya sigue. Re-suscribir en cada snapshot de shell en blanco en blanco silenciosamente la mitad inferior del panel.

### El feed de actividad

Cada par `tool.started`/`tool.completed` se pliega en una sola fila. Los dos no llevan un id compartido, y los comandos rápidos registran ambos dentro del mismo milisegundo sin campo `sequence`, así `orderedActivities` rompe empates por orden de ciclo de vida: sin eso, la mitad de todos los comandos finalizados se leen como aún en curso, y el mismo empate podría dejar una aprobación resuelta como pendiente. Los comandos se desenrollan del `/bin/zsh -lc "…"` que el agente los corre, y las rutas de archivos cambiados se muestran relativas al worktree.

### Agentes finalizados

Un agente finalizado permanece fijado como una tarjeta Hecho hasta que es revisado, en lugar de pasar rápidamente. Su barra de revisión está al pie del panel, bajo lo que el agente realmente hizo. Dos cosas la limpian: presionar **Abrir en T3 Code** en el notch, o estabilizar el hilo en T3 Code (`settledAt`). El propio estado de lectura de T3 Code vive en el almacenamiento local del renderer (`threadLastVisitedAtById`) y no se expone vía HTTP, así que simplemente abrir el hilo en la ventana de T3 Code no puede limpiar el notch. Los hilos que ya habían finalizado cuando el notch arrancó se tratan como vistos, así la primera instantánea no fija todo el historial.

**Abrir en T3 Code** lleva la app de escritorio al frente cuando está corriendo y solo cae en una pestaña de navegador cuando no. T3 Code registra `t3code://` pero no maneja rutas de hilos: una segunda instancia simplemente revela la ventana existente, así la app llega a cualquier hilo que ya estuviera mostrando en lugar del de la notch. La activación va a través de LaunchServices (`NSWorkspace.openApplication`), porque `NSRunningApplication.activate()` es ignorada para un llamador que no es él mismo activo, lo cual el panel de notch no-activador nunca es. Desactiva **Abrir en la app de T3 Code** para siempre usar el navegador, que hace deep-link al hilo exacto.

### Detectar merges

El estado de merge solo se sirve vía el RPC de WebSocket de T3 Code (`subscribeVcsStatus`, `getVcsStatus`) y esta app habla el API de orquestación HTTP, así merges se encuentran sin preguntárselo. Dos fuentes se consultan, las mismas dos que usa T3 Code:

- **El forge**, vía `gh pr list --head <branch> --state merged --limit 1`, como máximo una vez por minuto por rama. Esta es la única fuente que puede ver un merge squash: squashing reescribe los commits, así una rama mergeada con squash nunca es un ancestro de su base y ningún git local dirá lo contrario. También es lo que el mismo T3 Code impulsa, lo cual es por qué auto-estabiliza un hilo tan pronto como su solicitud de cambio reporta `merged`. Solo los pull requests mergeados después del inicio cuentan, así el historial permanece tranquilo. Un `gh` faltante, no-autorizado o no-forge hace back-off 15 minutos en lugar de spawnear un proceso por sondeo.
- **El repositorio local**, para ramas que aterrizan como un merge commit real o un fast-forward: `git rev-list --count <base>..<branch>` contra el trunk y `origin/HEAD`, de solo lectura, con `GIT_OPTIONAL_LOCKS=0`. Aquí un merge se reporta solo para una rama que fue vista llevando commits que la base carecía y luego dejó de llevarlos, porque "contenido por main" también es verdad de dos no-merges: un hilo que hace seguimiento al trunk, y una rama de worktree fresca que aún no ha comprometido nada.

Las ramas permanecen observadas hasta por 12 horas después de que su hilo deja de aparecer en el notch. Un pull request es usualmente mergeado bien después de que el agente para, y T3 Code auto-estabiliza el hilo tan pronto como ve el merge: así un vigilante que solo mirara hilos listados actualmente se volvería ciego exactamente cuando el merge aterriza.

### Auto-actualización

electron-updater, que T3 Code entrega a Squirrel a través de, publica un manifiesto `latest-mac.yml` junto a cada build. Una app de un solo activo necesita no manifiesto: el endpoint de versiones ya lleva la versión, las notas y la URL de descarga, y es la misma lista que una persona leería. Las etiquetas se comparan como semver en lugar de como strings, así `1.10.0` supera a `1.9.0` y `1.1.0-beta.1` permanece detrás de `1.1.0`; un asset que nombra otra arquitectura no es ofrecido incluso cuando es el único allí.

Instalar es una descarga, un `ditto -x` en un directorio temporal *en el propio volumen de la app*, y un solo `replaceItemAt`. Mismo volumen, porque un swap a través de volúmenes es una copia y una copia puede fallar a medio camino; un reemplazo atómico, porque un fallo entonces deja la app corriendo intacta en lugar de a medio sobreescrita. El bundle desempaquetado tiene que identificarse como esta app y llevar exactamente la versión que el lanzamiento prometió antes de que nada de eso suceda. Un script de relanzamiento espera por este proceso para salir antes de re-abrir, así no puede correr el riesgo del swap o dejar dos copias corriendo.

`ditto` en lugar de cualquier otro desempacador: es lo que escribió el zip, y es el que mantiene la firma del código intacta a través del viaje de ida y vuelta. Las actualizaciones solo se ofrecen a una app empaquetada: un binario corrido directo desde SwiftPM no tiene bundle para reemplazar, y la tarjeta dice eso en lugar de fallar después.

### Relojes

Las etiquetas de transcurrido leen un observable `clock` en el store que tickea una vez por segundo mientras el panel es visible y algún turno aún está abierto. Leer `Date()` dentro de una etiqueta parece equivalente pero se congela: SwiftUI re-renderiza en cambio observable, no en el paso del tiempo, así la etiqueta solo se movió cuando algo más lo hizo: lo cual, con el mouse quieto, era nada. Los turnos finalizados se clampan a su `completedAt` en lugar de contar hacia arriba para siempre.

### Ventanas y el panel

La ventana del panel es deliberadamente mucho más alta que lo que dibuja, así el panel puede abrirse sin redimensionarla, y solo acepta clicks cuando el pointer está sobre la parte dibujada. Aceptarlos en cualquier parte convierte el resto vacío en una trampa invisible sobre lo que esté debajo del notch.

Mientras una ventana de ajustes o de inicio rápido está abierta, la app cambia de `.accessory` a `.regular` activación y vuelve en cierre. Una app accessory no posee ningún Dock tile, entrada de ⌘Tab y menu bar, así una ventana abierta desde un ítem de status no puede ser encontrada de nuevo una vez algo la cubre: y sus propios shortcuts (⌘C, ⌘W, ⌘Q) necesitan un menu bar para existir en absoluto.

## Desarrollo

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test
```

Abre `Package.swift` en Xcode para vistas previas y debugging.

`Resources/AppIcon.icns` es generado, no dibujado a mano: `Scripts/MakeAppIcon.swift` lo dibuja con SwiftUI contra el propio `NotchShape` de la app, así el icono y el panel no pueden desviarse. Tamaños debajo de 64px bajan el detalle interior y 16px baja el punto de acento, porque ambos se convierten en papilla a esa escala. El ítem de menu bar dibuja la misma silueta a 20×11 como imagen de plantilla.

```bash
./Scripts/make-icon.sh   # reescribe Resources/AppIcon.icns
```

### Cortar un lanzamiento

**Actions → Release → Run workflow**, en un runner macOS 26 con el mismo Xcode 26.6 que la app es construida con localmente. Dale una versión (`1.1.0`, o `1.1.0-beta.1` en el canal de prerelease) y prueba, construye, Developer ID firma, notariza, estampa, chequea la descarga en cuarentena con Gatekeeper, y publica la etiqueta con el zip y su checksum.

El workflow lee la identidad de firma y la clave API de App Store Connect de un secreto cifrado de GitHub Actions. Sus valores nunca pertenecen al repositorio:
`DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`,
`APP_STORE_CONNECT_API_KEY`, `APP_STORE_CONNECT_KEY_ID`, y
`APP_STORE_CONNECT_ISSUER_ID`.

Desactiva **publish** para una prueba seca: el mismo build llega como un artifact del workflow y no se crea etiqueta. La versión y la etiqueta se chequear antes de que nada se construya, así un typo o una etiqueta existente falla en segundos en lugar de después de un build completo.

`CFBundleShortVersionString` debe coincidir con la etiqueta exactamente: es lo que el updater compara con el bundle descargado, y un mismatch enviaría una actualización que se niega a instalar. El workflow lo enforcing; `Scripts/bundle.sh` lee `VERSION` y `BUILD_NUMBER` del ambiente por la misma razón.
