# Licencias Firebase — 3106

## Integración realizada

- Se conserva la pantalla SwiftUI de activación y el gate que protege la navegación actual de 3106.
- El cliente nativo consulta Firebase Realtime Database por REST en `keys/{KEY}.json`. No incorpora el SDK de Firebase ni credenciales administrativas.
- La validación replica el flujo de la web: una key inexistente, marcada `REVOKED` o vencida se rechaza; `expiration` admite milisegundos Unix o `PERMANENTE`.
- En el primer uso, la licencia se vincula al identificador persistente del dispositivo y actualiza `hwid` y `lastUsedAt`. La app usa una escritura condicional `PUT` con ETag de Firebase y vuelve a leer si otra activación cambió el registro al mismo tiempo.
- La key se conserva en el Keychain. El vencimiento local se guarda en `UserDefaults`. La app vuelve a validar al pasar a primer plano y aproximadamente una vez por minuto.
- 3106 solo valida licencias. No incluye el generador, administrador ni la contraseña del panel web.

## Permisos y seguridad

La comprobación de solo lectura a una ruta aleatoria vacía devolvió `200` con `null`. No se hizo ninguna escritura de prueba, así que el permiso para reclamar keys debe confirmarse al activar una key real. Las reglas de Firebase deben permitir leer el registro de una key y actualizarlo para reclamar `hwid`/`lastUsedAt`; si lo bloquean, la app mostrará error de conexión.

La web entrega su cliente JavaScript públicamente y protege el administrador con una verificación local; no se copió ese control. La configuración pública del cliente Firebase no es una credencial administrativa. Si las reglas permiten lectura y escritura generales, un cliente modificado podría alterar licencias. Para producción, lo más seguro es aplicar reglas estrictas o mover la reclamación a una Cloud Function autenticada. El vínculo del iPhone usa un identificador de proveedor/fallback persistente, no un identificador físico imposible de falsificar.

La integración se basa en las rutas y campos públicos de la web y en la [documentación REST de lectura](https://firebase.google.com/docs/database/rest/retrieve-data), [escritura](https://firebase.google.com/docs/database/rest/save-data) y [referencia de Firebase Realtime Database](https://firebase.google.com/docs/reference/rest/database).

## Compilación y IPA

Este entorno Linux no incluye Xcode ni `xcodebuild`, por lo que no se pudo compilar, ejecutar en un iPhone ni exportar un IPA. En macOS, abre `ThreeOneOSSix.xcodeproj` con Xcode, configura el equipo de firma/provisionamiento, ejecuta **Product → Build** y luego **Product → Archive** para exportar el IPA desde Organizer.
