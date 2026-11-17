# Avatar2 patch files

Los cuatro paquetes `.3105` suministrados en `Avatar2.zip` están dentro de `Payload/3106.app/Avatar2/` en el IPA unsigned de build 28. También forman parte de los recursos del proyecto Xcode. La lógica fuente los copia una sola vez a la biblioteca interna de parches al cargarla.

El IPA asociado está en `../3106-3.2.5-build28-unsigned.ipa`. Ese IPA se reempaquetó para incluir los cuatro archivos, pero su ejecutable no se recompiló aquí; la copia automática a la biblioteca interna requiere una compilación hecha desde el proyecto actualizado. Los SHA-256 están registrados en `../SHA256SUMS.txt`.
