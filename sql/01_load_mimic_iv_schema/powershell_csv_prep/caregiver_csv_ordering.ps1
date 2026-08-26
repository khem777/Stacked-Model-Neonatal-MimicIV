#Ubicar el directorio (Colocar el directorio donde está la carpeta descomprimida)
$directorio = "D:\emmanuel\uninorte\tesis\ModelosPredictivos\postgres_data\csv\icu\caregiver"

#Definir el archivo de salida
$csvSalida = "D:\emmanuel\uninorte\tesis\ModelosPredictivos\postgres_data\csv\icu\caregiver.csv"

# Obtener todos los archivos, ordenados por nombre ascendente
$archivos = Get-ChildItem -Path $directorio -File | Sort-Object Name

# Tomar el último archivo (alfabéticamente)
$ultimoArchivo = $archivos[-1]

# Tomar los demás archivos (sin el último)
$restoArchivos = $archivos[0..($archivos.Count - 2)]

# Crear lista con el último primero, luego los demás
$listaFinal = @($ultimoArchivo) + $restoArchivos

# Escribir al CSV solo los nombres de archivo, sin cabecera
$listaFinal | ForEach-Object { $_.Name } | Set-Content -Path $csvSalida