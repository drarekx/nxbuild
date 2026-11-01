# Mejoras pendientes para NX Build

Lista sacada de [LNPANDY/NX2Apple](https://github.com/LNPANDY/NX2Apple) (commit `758569c`, 2 nov 2026). Su app de Mac
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
23. **Actualización automática de la app**, con la descarga verificada por SHA-256, y del repositorio
    (versión estable o experimental). Archivos: `AppUpdate.swift` y `EngineUpdater.swift`.
24. **Desinstalar**: borra todo lo que la app creó fuera de su paquete. Archivo: `Uninstall.swift`.
25. **Modo consola**: pantalla completa manejada con el mando. Varios idiomas. Icono propio. Tests de rendimiento.

## Ideas propias (no vienen de NX2Apple)

26. **DLC en la biblioteca.** Una app de Mac lleva sus DLC en `Contents/Resources/aoc/<índice>/` (`dm/mac/pack_app.py`), y
    `launcher.c` se los pasa al juego como `DM_AOC_DIR`. Tareas:
    - En la tarjeta de cada juego, mostrar cuántos DLC lleva y sus índices. El title ID de cada uno es base + 0x1000 + índice.
    - Botón **«Añadir DLC y reconstruir»**: elegir o soltar los NSP de DLC, unirlos a los archivos con los que se construyó
      el juego (su carpeta, o los enlaces de `~/NX Build/<juego>`) y lanzar la build con el mismo destino. La build
      reutiliza lo que no ha cambiado y la partida guardada no se toca.
    - Avisar de los DLC que son solo una licencia: NSP de menos de 1 MB sin contenido. El script ya lo indica en su informe.
    - Para saber con qué archivos se construyó cada app, guardar en `library.json` la carpeta de origen de cada build.
