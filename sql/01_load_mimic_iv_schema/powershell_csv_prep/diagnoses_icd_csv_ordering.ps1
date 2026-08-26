# Ubicar la carpeta donde vamos a sacar los archivos
$origen = "D:\emmanuel\uninorte\tesis\modelospredictivos\postgres_data\csv\hosp\diagnoses_icd"

# Ubicar la carpeta de copia
$destino = "D:\emmanuel\uninorte\tesis\modelospredictivos\postgres_data\csv\hosp\copia"

# Extraer los primeros 250.000 archivos
$archivos = Get-ChildItem -Path $origen -File | Select-Object -First 250000

# Mover los archivos a carpeta de copia
foreach ($archivo in $archivos) { Move-Item -Path $archivo.FullName -Destination $destino }

#Ubicar el directorio donde tenemos todos los archivos para cargar al CSV
$directorio_origen = "D:\Emmanuel\Uninorte\Tesis\ModelosPredictivos\postgres_data\csv\hosp\copia"

#Definir el archivo de salida CSV
$csvSalida = "D:\emmanuel\uninorte\tesis\ModelosPredictivos\postgres_data\csv\hosp\diagnoses_icd.csv"

# Obtener todos los archivos
$archivos = Get-ChildItem -Path $directorio_origen -File 

# Escribir al CSV solo los nombres de archivo, sin cabecera
$archivos | ForEach-Object { $_.Name } | Add-Content -Path $csvSalida
