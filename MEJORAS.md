# Mejoras pendientes para NX Build

Lista sacada de [LNPANDY/NX2Apple](https://github.com/LNPANDY/NX2Apple) (commit `758569c`, 2 nov 2026; revisada hasta `994ede7` el 6 nov 2026, ver «Novedades» al final). Su app de Mac
se llama NSPortBuilder y está en `frontend/`. Hace lo mismo que NX Build (una interfaz para
`scripts/build_ipa_from_nsp.py`) y bastante más. Aquí solo está lo que ellos hacen y NX Build no.
Lo he sacado de su README, de `frontend/README.md` y de los comentarios de cabecera de sus archivos Swift.
No he ejecutado su app.

**Lo que NX Build ya tiene:**
- Elegir o arrastrar la carpeta de los NSP, y elegir prod.keys.
- Destino: app de Mac o IPA de iPhone.
- Comprobar la versión de Metal.
- Opciones avanzadas.
- Progreso con `--progress json`: etapas, barra y tiempo restante.
- Log en la ventana y botón de cancelar (señal de interrupción).
- «Mostrar en Finder» y «Abrir logs».
- Ajustes de rutas.
- Ventana de dependencias que comprueba e instala, y venv local.

**Aviso:** algunas mejoras necesitan parches que solo tiene su fork (`patches/`). Nuestro nxnative (`cd859c38`) no tiene
`--shell-framework`, `dm/host/input_map.h` ni `dm/ios/tools/build_shell.sh`. Sí tiene `dm/games/settings.tsv` y
`dm/host/hle_cheats.c`. Las mejoras afectadas llevan la marca **[parche]**.

---

## Prioridad alta: hacen las builds más fiables

1. ✅ **Hecho (1 nov 2026).** **Parar toda la build, no solo Python.** Ellos lanzan el script en su propio grupo de procesos
   (`os.setpgid(0,0)` y luego `execv`) y lo paran con `killpg` (primero SIGTERM y después SIGKILL). También lo paran al cerrar la app.
   - Nosotros mandamos SIGINT solo a Python, así que dotnet, metal, xcodebuild y compañía pueden quedarse vivos.
   - Al cerrar NX Build durante una build, la build no se para.
   - Archivo de referencia: `ContentView.swift:252-284`.
2. ✅ **Hecho (1 nov 2026).** **Explicar por qué ha fallado una build.** Leen el final del log, no solo la última línea, y convierten los fallos típicos
   en un paso siguiente concreto: claves demasiado viejas, NSP dañado, disco desconectado, fallo al instalar…
   Hace falta leer el final del log porque en un NSP dañado la última línea es solo `nx_extract exit code 3`.
   Archivos: `BuildFailure.swift` y `BuildFailureView.swift`.
3. ✅ **Hecho (1 nov 2026).** **Comprobar prod.keys antes de construir.** Descifran con `header_key` la cabecera de cada NCA del NSP o NSZ
   (base, update y DLC) y miran si el archivo tiene las claves de la generación que pide cada uno. Así unas claves viejas
   se ven antes de empezar, no varios minutos después en la extracción. Un XCI no se puede comprobar así y la app lo dice.
   Nunca muestran el valor de una clave. Archivo: `KeyCheck.swift`.
4. ✅ **Hecho (1 nov 2026).** **Avisar si la carpeta de salida está en iCloud u otra nube** (Mobile Documents, CloudStorage, Escritorio o Documentos
   sincronizados). La nube añade atributos a los archivos y codesign falla en el último paso, a veces después de una hora.
   Archivo: `CloudFolder.swift`.
5. ✅ **Hecho (1 nov 2026).** **Arrastrar archivos sueltos.** Se pueden soltar NSP, NSZ, XCI y prod.keys mezclados. Los reparten en base, update y DLC
   según el title ID del nombre. Si los archivos están en varias carpetas, crean una carpeta fija dentro de `<id>_build`
   con un enlace a cada archivo, para que la caché del script no cambie entre builds.
   Archivos: `DropFiles.swift` e `InputStaging.swift`.
6. ✅ **Hecho (1 nov 2026).** **Notificación y barra en el Dock.**
   - Aviso del sistema cuando una build termina o falla con la app en segundo plano. Al pulsarlo se abre el juego o el log.
   - Barra de progreso sobre el icono del Dock.
   - Archivos: `BuildNotifications.swift` y `DockProgress.swift`.
7. ✅ **Hecho (1 nov 2026).** **Liberar espacio.** Borran de `<id>_build` lo que la siguiente build vuelve a generar: `extract/`, `shader/`, `pso/`,
   `xcode*/` e `ipa/`. Conservan `logs/`, `profile/`, `run/` y `nsp/`. Archivo: `FreeSpace.swift`.
8. ✅ **Hecho (1 nov 2026).** **Copiar diagnóstico.** Copian al portapapeles un informe en Markdown con:
   - la versión de la app, de macOS y el chip;
   - el commit del repositorio y cuánto va por detrás;
   - el Python y el .NET que se usan, y el resultado de la comprobación de dependencias;
   - las versiones de Xcode y Metal comparadas con el `.lock`, y el SDK de iOS;
   - el último comando de build y las últimas 50 líneas del log.

   La carpeta de usuario aparece como `~` y los valores de las claves se borran. Archivo: `Diagnostics.swift`.
9. ✅ **Hecho (1 nov 2026).** **Dependencias más sólidas.**
   - Guardan cada comprobación en `deps-check.txt`, con el PATH y los intérpretes que han probado.
   - Buscan Python también en los instalados por uv (`~/.local/share/uv/python`) y en los de python.org, y eligen el
     primero que puede importar todos los módulos.
   - Archivos: `BundledTools.swift` y el apartado «Why the dependency check does not use `which`» de su README.

## Prioridad media: biblioteca y jugar

10. ✅ **Hecho (1 nov 2026).** **Biblioteca de juegos construidos.**
    - Revisa la carpeta de juegos hasta 4 niveles de profundidad y muestra el estado de cada juego (listo, construyendo, sin construir).
    - Botón **Jugar**.
    - La imagen de cada juego viene de la tienda de Nintendo, buscada por title ID en blawar/titledb, con portada propia opcional.
    - Archivos: `Library.swift`, `LauncherView.swift` y `Artwork.swift`.
11. ✅ **Hecho (1 nov 2026).** **Opciones de lanzamiento por juego**: fps, modo dock o portátil, escala, idioma… Se leen de
    `Contents/Resources/dm/launcher.json` dentro de la app construida y se guardan como `launcher.<VAR>` en las preferencias
    de esa app, que `launcher.c` lee en cada arranque. Archivos: `SavedChoices.swift` y `LaunchOptionsView.swift`.
12. **Partidas guardadas entre Mac y iPhone.** Se copian con `devicectl device copy from/to`, se compara la fecha de cada lado
    y se hace copia de seguridad antes de sobrescribir. Archivo: `SaveTransfer.swift`.
13. **Trucos (cheats).** Importan carpetas de Ryujinx o Atmosphère, activan y desactivan cada truco en `<build ID>.enabled`
    y los copian al iPhone. Usa `hle_cheats.c`, que nosotros ya tenemos.
    Archivos: `CheatsView.swift` y `CheatFiles.swift`.
14. **Grabar tiempos de fotograma.** Al jugar pasan `DM_NVN_TSV` y luego dibujan la gráfica con percentiles.
    Archivos: `FrameTimes.swift` y `FrameTimesView.swift`.
15. **Marcar juegos hechos con herramientas viejas.** Guardan el commit del repositorio en cada build y comparan con el actual
    los archivos que afectan a la build. Archivo: `OlderTools.swift`.
16. **Volver al frente** cuando se cierra el juego. Archivo: `ReturnAfterPlay.swift`.
17. **Teclas y mando** (`DM_KEYMAP`, `DM_PAD_MAP`, distribución automática según el mando). **[parche]** `input_map.h`.
    Archivos: `Controls.swift` y `ControlPresets.swift`.

## iPhone

18. **Instalar directamente en el iPhone.**
    - Lista los dispositivos con `devicectl list devices` y los equipos de firma con `security find-identity`.
    - Firma con `xcodebuild -allowProvisioningUpdates` e instala con `devicectl device install app`.
    - Archivos: `Devices.swift` y `ShellInstall.swift`.
19. **Una sola app en el iPhone para todos los juegos**, copiando a `Documents/games/<id>/` solo los archivos que faltan.
    **[parche]** `--shell-framework` y `build_shell.sh`.
20. **Aviso de caducidad de la firma de 7 días** (Apple ID gratuito) y botón para volver a firmar. Leen `ExpirationDate`
    de `embedded.mobileprovision`. Archivo: `AppSignature.swift`.

## Prioridad baja: distribución y extras

21. **Herramientas y Python dentro del .app.** Llevan zstd, glslang, spirv-cross, xcodegen y CPython 3.13 con los módulos
    ya instalados, así que no hace falta Homebrew. .NET sigue instalándose aparte.
22. **Asistente de primer arranque** que guía por Xcode, las claves y los juegos. Archivos: `Onboarding*.swift`.
23. ✅ **Hecho en parte (1 nov 2026, v1.0.0):** la app se actualiza sola desde GitHub con SHA-256. Falta la del repositorio nxnative. **Actualización automática de la app**, con la descarga verificada por SHA-256, y del repositorio
    (versión estable o experimental). Archivos: `AppUpdate.swift` y `EngineUpdater.swift`.
24. **Desinstalar**: borra todo lo que la app creó fuera de su paquete. Archivo: `Uninstall.swift`.
25. ✅ **Hecho en parte (2 nov 2026, v1.3.0–1.3.1):** inicio tipo consola con mando e icono propio. Faltan pantalla completa, idiomas y tests de rendimiento. **Modo consola**: pantalla completa manejada con el mando. Varios idiomas. Icono propio. Tests de rendimiento.

## Ideas propias (no vienen de NX2Apple)

26. **DLC en la biblioteca.** Una app de Mac lleva sus DLC en `Contents/Resources/aoc/<índice>/` (`dm/mac/pack_app.py`), y
    `launcher.c` se los pasa al juego como `DM_AOC_DIR`. Tareas:
    - En la tarjeta de cada juego, mostrar cuántos DLC lleva y sus índices. El title ID de cada uno es base + 0x1000 + índice.
    - Botón **«Añadir DLC y reconstruir»**: elegir o soltar los NSP de DLC, unirlos a los archivos con los que se construyó
      el juego (su carpeta, o los enlaces de `~/NX Build/<juego>`) y lanzar la build con el mismo destino. La build
      reutiliza lo que no ha cambiado y la partida guardada no se toca.
    - Avisar de los DLC que son solo una licencia: NSP de menos de 1 MB sin contenido. El script ya lo indica en su informe.
    - Para saber con qué archivos se construyó cada app, guardar en `library.json` la carpeta de origen de cada build.

48. ✅ **Hecho (6 nov 2026, v1.6.0): mover un juego a otro disco.** Biblioteca › Mover a otro disco…: la app, su
    carpeta de build y los NSP/NUP/dump (resolviendo los enlaces de ~/NX Build), con ditto, comprobación de bytes y borrado
    del original al final; extract/ y tmp/ no viajan salvo que se pida. `GameMove.swift`, `MoveGameView.swift`.

## Novedades de NX2Apple (revisión del 2 nov 2026, `758569c` → `6d1c3007`)

222 commits. La mayoría reorganizan su código (NXCore, NXModel, NXLauncher, stores) o pasan los textos a JSON
(`frontend/l10n/`, ahora también italiano). Lo que aporta algo nuevo a NX Build:

Apuntado el 2 nov 2026, pendiente. Orden sugerido: 35, 27, 30 (rápidas); luego 31, 33 y 32.

27. **Avisar si la carpeta de salida está en un disco externo o en exFAT.** Es también la caché de la build, y en exFAT por
    USB cada archivo pequeño tarda unas 14 veces más (1,7 ms frente a 0,12 ms): la primera build va mucho más lenta.
    Además, en exFAT cada archivo lleva un `._nombre` al lado que rompe la firma de la app de Mac (ver 28). Mirar el
    sistema de archivos del volumen (`volumeLocalizedFormatDescription` / `statfs`) al elegir la carpeta. Commit `38aafc5b`.
28. ✅ **Motor (6 nov 2026, nxnative `998896ac`):** `pack_app.py` ya salta los `._`. **[motor] Archivos `._` de exFAT que rompen la app de Mac.** Su parche 0056 (enviado a seedds/nxnative#991) hace que
    `pack_app.py` los salte. Nuestro nxnative (`65501fbb`) aún no lo tiene. Mientras tanto, NX Build puede
    bloquear o avisar al construir una app de Mac en exFAT, o pasar `dot_clean` antes de empaquetar. Commit `09bc20ac`.
29. ✅ **Motor (6 nov 2026, nxnative `65cc2af4` y `b1c20372`):** los dos arreglos ya están en nuestro nxnative. **[motor] NSP con la tabla de nombres sin el último terminador** (parche 0058) y **llamadas de cola sin marco antes del
    relleno** (parche 0059, `dm/tools/patch_nso.py`). No están en nuestro nxnative. Si un NSP falla en `nx_extract`
    con un PFS0 «roto», puede ser esto: añadirlo a las explicaciones de fallo de `BuildFailure.swift`.
30. **Pantalla completa y pantalla del lanzador al jugar desde el modo consola.** Al pulsar Jugar en su modo consola pasan
    `DM_FULLSCREEN=1` y `DM_SCREEN` (la pantalla donde está el lanzador). Nuestro nxnative lo admite (`front_mac.m`,
    `docs/settings.md`). En NX Build: opción «Jugar a pantalla completa desde el inicio».
31. **Mods con `DM_ROMFS_OVERLAY`.** Una carpeta que se superpone a la RomFS del juego. Nuestro nxnative lo admite
    (`hle_fs.c`). En NX Build: sección «Mods» en las opciones de lanzamiento, que elija la carpeta y la pase al jugar.
32. **Batería de los mandos y ocultar el puntero en el modo consola.** Muestran la batería de cada mando conectado
    (`GCController.battery`) y esconden el puntero tras unos segundos sin moverlo.
33. **Ampliada en la 37.** **Construir desde una carpeta con los archivos del juego, sin NSP ni prod.keys.** Nuestro nxnative ya lo hace
    (`pack_dump.py`, `dump_folder` en `build_ipa_from_nsp.py`); ellos aún no lo ofrecen en el lanzador (#445). NX Build
    podría aceptar esa carpeta y no pedir claves en ese caso.
34. **Restablecer cada opción por separado.** Una flecha junto a cada opción que no está en su valor probado (nosotros solo
    tenemos «Restablecer valores probados» para todas).
35. **Crear carpetas en el diálogo de la carpeta de salida** (`canCreateDirectories`). Trivial. Commit `c581ba1e`.
36. **iPhone, solo con la app compartida [parche]:** exportarla como IPA sin firmar con los juegos dentro y enviar los datos
    del juego a un dispositivo o a un disco (`ShellExport.swift`, `DriveCopy.swift`, commit `8a71b119`); preguntar antes de
    construir si la app compartida lleva frameworks de una cadena de shaders vieja (`StaleFrameworksPrompt.swift`). Solo
    tienen sentido si algún día hacemos la 19.

## Novedades de NX2Apple (revisión del 6 nov 2026, `6d1c3007` → `994ede7`)

217 commits (de su v1.0.2 a la v1.2.2). Mucho es iOS (app compartida, controles táctiles), Qt/Windows, traducciones y
subidas del motor. Lo que sirve a NX Build (nuestro nxnative en `0f510fd5`):

Orden sugerido: 38, 39 y 40 (rápidas, solo `BuildFailure.swift` y la vista de progreso); luego 37, 41 y 42.

37. ✅ **Hecho (6 nov 2026, v1.6.0).** **Juegos de Switch 2 desde un NUP o una carpeta, sin prod.keys.** Aceptan un `.nup` (o una carpeta que lo tenga) y una
    carpeta con `base/exefs/main.npdm`: leen el title ID, las actualizaciones y los DLC, no piden claves y no pasan `-k`.
    Avisan antes de construir si la copia está incompleta, si hay dos NUP en la carpeta o si el motor no tiene
    `pack_nup.py` / `pack_dump.py`. Ya no exigen perfil: el motor hace uno provisional (`survey_nup` / `survey_dump`).
    Marcan los juegos de Switch 2 en la biblioteca. Nuestro nxnative lo admite todo (`scripts/pack_nup.py`,
    `pack_dump.py`, `survey_nup` en `build_ipa_from_nsp.py`; NUP sin juego base desde `777a5f6c`). En NX Build:
    `GameFiles.extensions` solo tiene nsp/nsz/xci/xcz; añadir `nup`, reconocer la carpeta, y en `KeyCheck` y
    `ContentView` no pedir prod.keys en esos casos. Commits `f36096e`, `034add2`, `1148600`, `0645efa`, `334a69e`.
38. ✅ **Hecho (6 nov 2026, v1.6.0).** **Fallo «claves más viejas que el juego».** El motor para la build al momento si a prod.keys le falta la master key del
    juego (`nx_extract` sale con código 6; el mensaje dice «the keys are older than the game» y nombra la clave y el
    firmware). Ellos lo explican y ofrecen elegir otro prod.keys. En `BuildFailure.swift` el patrón de `.keysOld` no
    incluye ese texto: añadir `keys are older than the game` y mostrar la clave y el firmware. Commit `2fead4b`.
39. ✅ **Hecho (6 nov 2026, v1.6.0)**, también como nota cuando la etapa acaba con aviso. **Fallo por falta de espacio al compilar el archivo de pipelines.** `pso_offline.py` escribe «metal-tt needs about N GB»,
    «GB free before merging; need at least» y «when it failed: likely out of disk space». Ellos lo clasifican como disco
    lleno y dicen cuántos GB hacen falta. Nuestro `.diskFull` no reconoce esos textos. Commit `4869fe8`.
40. ✅ **Hecho (6 nov 2026, v1.6.0).** **Avisar de que los últimos archivos del split de shaders tardan.** El split informa por lotes de hasta 16 archivos y
    se queda en 99 % varios minutos con el último. Cuando faltan 16 o menos (etapa «shader split», paso «splitting»,
    unidad «files»), muestran «Revisar los últimos archivos puede tardar varios minutos». En NX Build: en la línea de
    progreso de `ContentView` / `BuildRunner.current`. Commit `31abb7f`.
41. **Borrar un juego desde el lanzador.** Una hoja que lista lo que va a la Papelera con su tamaño (app de Mac, IPA,
    carpeta de build, log); las partidas son un interruptor aparte que empieza apagado; nunca toca los archivos de origen;
    desactivado durante una build. En NX Build: menú del juego en la biblioteca (`CollectionView` / `Library.swift`),
    reutilizando el cálculo de tamaños de `FreeSpace.swift`. Commit `4da2903`.
42. **Carpeta de partidas en la nube por juego y última sincronización.** Muestran qué carpeta cuenta, en el orden de
    `dm/mac/launcher.c` (env.txt del jugador, env.txt de la app, `cloudSaves.folder` en las preferencias), de dónde sale,
    y permiten cambiarla o apagarla. Nosotros solo mostramos la etiqueta en `ConsoleHome`. Commit `7891bc9`.
43. **Portadas de Switch 2 que no están en titledb.** Una lista fija de title ID → imagen 16:9 para los juegos de Switch 2
    que titledb aún no trae (Ocarina of Time, Star Fox, Yoshi, Mario Tennis Fever…). Y cuando un title ID tiene varios
    productos (Switch 2 Edition, packs, demos), eligen el del juego. En NX Build: `Covers.swift`. Commits `fee5c16`, `2d32645`.
44. **La biblioteca sube un nivel cuando el juego base está en una subcarpeta** y sus hermanas tienen las
    actualizaciones o los DLC (`Base/`, `Update/`, `DLC/`), para tratarlo como un solo juego. Commit `8c65c26`.
45. **Explicar por qué un juego no tiene opción de resolución** (no hay fila de escala en su build, p. ej. Xenoblade 2) y
    nombrar las opciones más cercanas (modo consola, reescalado). En las opciones de lanzamiento. Commit `b97eb40`.
46. **[parche] Joy-Con separados como dos mandos de lado** (`DM_JOYCON_SPLIT=1`) y **Steam Controller 2026** con
    mapeos por juego. No están en nuestro nxnative. Commits `fc56ca3`, `94f5604`.
47. **[parche] «Constructor experimental» `nxbuild`/`nxb`**: un binario aparte que hace la extracción y el split de shaders
    mucho más rápido, byte a byte igual; el script lo usa si está (`DM_EXPERIMENTAL_BUILDER=1`, `NXB_BIN`) y si no, el
    paso de Python. Depende de su parche 0073 (enviado como seedds/nxnative#1325). Vigilar si llega a upstream.
    Commits `2280f43`, `28b97f5`, `98c0340`.

Ya hecho o no aplica: avisar del formato del disco antes de una app de Mac (`baf78f2`, es nuestra 27, pendiente);
extensiones en mayúsculas y `swap_by_moves` en volúmenes no APFS ya están en nuestro nxnative (`7dc00e4d`, `5061b2a1`);
la opción de 120 fps la ofrece el motor desde el perfil (`fps_max`), y NX Build ya la muestra porque lee las opciones
del `launcher.json` de cada app (`LaunchSettings.swift`).

