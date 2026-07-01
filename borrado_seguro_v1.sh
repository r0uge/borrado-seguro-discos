#!/bin/bash
#
# borrado_seguro_v2.sh
# Script de borrado seguro de discos para pendrive/CD booteable (live).
# Basado en borrado_seguro_v1.sh (https://github.com/r0uge/Borrado_Seguro)
# con correcciones de seguridad y robustez.
#
# IMPORTANTE: Este script es DESTRUCTIVO e IRREVERSIBLE. Está pensado para
# correr desde un medio live (pendrive/CD) que NO sea uno de los discos a
# borrar. Revisá la lista de discos detectados antes de confirmar.
#
set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------
# Configuración
# ------------------------------------------------------------------
LOGDIR="/root/borrado_seguro_logs"
TS="$(date +%Y%m%d_%H%M%S)"
LOGFILE="${LOGDIR}/borrado_${TS}.log"
REPORT="${LOGDIR}/certificado_borrado_${TS}.txt"
HDPARM_PASS="p"          # password temporal usado por hdparm --security-set-pass
SHRED_PASSES=3

mkdir -p "$LOGDIR"

log() {
    echo -e "$1" | tee -a "$LOGFILE"
}

die() {
    log "ERROR: $1"
    exit 1
}

# ------------------------------------------------------------------
# Verificaciones previas
# ------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    die "Este script debe ejecutarse como root (sudo)."
fi

log "=== Borrado seguro de discos - inicio $(date) ==="

# --- Instalar dependencias faltantes -------------------------------------
REQUIRED_PKGS=(hdparm nvme-cli util-linux smartmontools coreutils)
REQUIRED_BINS=(hdparm nvme lsblk blkdiscard findmnt smartctl shred)

missing_bins=()
for b in "${REQUIRED_BINS[@]}"; do
    command -v "$b" >/dev/null 2>&1 || missing_bins+=("$b")
done

if [[ ${#missing_bins[@]} -gt 0 ]]; then
    log "Faltan comandos: ${missing_bins[*]}. Intentando instalar dependencias..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >>"$LOGFILE" 2>&1 || log "Aviso: apt-get update falló (¿sin red? revisá el repo local del live)."
        apt-get install -y "${REQUIRED_PKGS[@]}" >>"$LOGFILE" 2>&1 \
            || die "No se pudieron instalar las dependencias. Instalalas manualmente: ${REQUIRED_PKGS[*]}"
    else
        die "No se encontró apt-get. Instalá manualmente: ${REQUIRED_PKGS[*]}"
    fi
    log "Dependencias instaladas correctamente."
else
    log "Todas las dependencias necesarias están presentes."
fi

# ------------------------------------------------------------------
# Detectar el/los disco(s) del sistema live (para EXCLUIRLOS siempre)
# ------------------------------------------------------------------
protected_disks=()

# Disco que contiene la raíz montada actualmente
root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
if [[ -n "$root_src" ]]; then
    root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"
    [[ -n "$root_disk" ]] && protected_disks+=("$root_disk")
fi

# Cualquier disco marcado como transporte usb (típico de pendrives live)
while read -r name tran; do
    [[ "$tran" == "usb" ]] && protected_disks+=("$name")
done < <(lsblk -dno NAME,TRAN)

# Deduplicar
mapfile -t protected_disks < <(printf '%s\n' "${protected_disks[@]}" | sort -u)

log "Discos protegidos (NO se tocarán): ${protected_disks[*]:-ninguno detectado}"

is_protected() {
    local d="$1"
    for p in "${protected_disks[@]}"; do
        [[ "$d" == "$p" ]] && return 0
    done
    return 1
}

# ------------------------------------------------------------------
# Detectar discos candidatos (sata / nvme, no usb, no protegidos)
# ------------------------------------------------------------------
candidate_disks=()
while read -r name type tran; do
    [[ "$type" != "disk" ]] && continue
    [[ "$tran" != "sata" && "$tran" != "nvme" ]] && continue
    is_protected "$name" && continue
    candidate_disks+=("$name")
done < <(lsblk -dno NAME,TYPE,TRAN)

if [[ ${#candidate_disks[@]} -eq 0 ]]; then
    die "No se detectaron discos candidatos para borrar (sata/nvme, excluyendo el disco de sistema/usb)."
fi

# ------------------------------------------------------------------
# Mostrar detalle y pedir confirmación explícita
# ------------------------------------------------------------------
log "\nDiscos detectados para borrado seguro:"
log "----------------------------------------------------------------"
printf "%-10s %-8s %-25s %-20s %-10s\n" "DISPOSITIVO" "TRAN" "MODELO" "SERIAL" "TAMAÑO" | tee -a "$LOGFILE"
for d in "${candidate_disks[@]}"; do
    model=$(lsblk -dno MODEL "/dev/$d" 2>/dev/null | xargs)
    serial=$(lsblk -dno SERIAL "/dev/$d" 2>/dev/null | xargs)
    size=$(lsblk -dno SIZE "/dev/$d" 2>/dev/null | xargs)
    tran=$(lsblk -dno TRAN "/dev/$d" 2>/dev/null | xargs)
    printf "%-10s %-8s %-25s %-20s %-10s\n" "/dev/$d" "$tran" "${model:-?}" "${serial:-?}" "${size:-?}" | tee -a "$LOGFILE"
done
log "----------------------------------------------------------------"

echo
read -r -p "Esta operación BORRARÁ DE FORMA IRREVERSIBLE los discos listados. Escribí BORRAR para continuar: " confirm
if [[ "$confirm" != "BORRAR" ]]; then
    die "Confirmación no coincide. Abortando sin hacer cambios."
fi

# Confirmación individual por disco (segunda barrera de seguridad)
disks_to_wipe=()
for d in "${candidate_disks[@]}"; do
    read -r -p "  ¿Confirmás borrar /dev/$d? (s/N): " ans
    if [[ "$ans" =~ ^[sS]$ ]]; then
        disks_to_wipe+=("$d")
    else
        log "/dev/$d omitido por el usuario."
    fi
done

[[ ${#disks_to_wipe[@]} -eq 0 ]] && die "No quedó ningún disco confirmado. Abortando."

# ------------------------------------------------------------------
# Funciones de borrado por método
# ------------------------------------------------------------------
declare -A RESULT
declare -A METHOD_USED

wipe_nvme() {
    local dev="/dev/$1"
    log "[$1] NVMe detectado. Intentando format --ses=1 (secure erase)..."
    if nvme format "$dev" --ses=1 >>"$LOGFILE" 2>&1; then
        METHOD_USED[$1]="nvme format --ses=1 (crypto/user data erase)"
        return 0
    fi
    log "[$1] format --ses=1 falló, probando --ses=2 (crypto erase)..."
    if nvme format "$dev" --ses=2 >>"$LOGFILE" 2>&1; then
        METHOD_USED[$1]="nvme format --ses=2 (crypto erase)"
        return 0
    fi
    log "[$1] format seguro falló, probando format simple (sin ses)..."
    if nvme format "$dev" >>"$LOGFILE" 2>&1; then
        METHOD_USED[$1]="nvme format (sin secure erase - AVISO: no es borrado criptográfico)"
        return 0
    fi
    return 1
}

wipe_ata_secure_erase() {
    local disk="$1"
    local dev="/dev/$disk"

    if ! hdparm -I "$dev" 2>/dev/null | grep -q "supported: enhanced erase\|Security.*supported"; then
        return 2   # no soportado
    fi

    if hdparm -I "$dev" 2>/dev/null | grep -qi "frozen"; then
        log "[$disk] El disco está en estado FROZEN. hdparm no puede setear password."
        log "[$disk] Solución: suspender y reanudar el equipo (suspend-to-RAM), o hacer hot-plug del disco (si es hot-swap), y volver a correr el script sobre este disco."
        return 2
    fi

    log "[$disk] Seteando password temporal de seguridad ATA..."
    if ! hdparm --user-master u --security-set-pass "$HDPARM_PASS" "$dev" >>"$LOGFILE" 2>&1; then
        log "[$disk] No se pudo setear el password de seguridad."
        return 1
    fi

    log "[$disk] Ejecutando security-erase (puede tardar bastante)..."
    if hdparm --user-master u --security-erase "$HDPARM_PASS" "$dev" >>"$LOGFILE" 2>&1; then
        METHOD_USED[$disk]="ATA Secure Erase (hdparm)"
        return 0
    else
        log "[$disk] security-erase falló. Intentando desbloquear el disco (security-disable) para no dejarlo inutilizable..."
        hdparm --user-master u --security-disable "$HDPARM_PASS" "$dev" >>"$LOGFILE" 2>&1 \
            || log "[$disk] ADVERTENCIA: no se pudo revertir el password de seguridad. El disco podría haber quedado bloqueado. Requiere intervención manual con hdparm --security-disable."
        return 1
    fi
}

wipe_blkdiscard() {
    local disk="$1"
    local dev="/dev/$disk"
    log "[$disk] Intentando blkdiscard (TRIM completo, apto para SSD sin secure erase ATA)..."
    if blkdiscard -s "$dev" >>"$LOGFILE" 2>&1 || blkdiscard "$dev" >>"$LOGFILE" 2>&1; then
        METHOD_USED[$disk]="blkdiscard (TRIM/UNMAP completo)"
        return 0
    fi
    return 1
}

wipe_shred() {
    local disk="$1"
    local dev="/dev/$disk"
    log "[$disk] Disco rotacional (HDD) sin secure erase ATA disponible. Usando shred (${SHRED_PASSES} pasadas + cero final)..."
    if shred -n "$SHRED_PASSES" -z -v "$dev" >>"$LOGFILE" 2>&1; then
        METHOD_USED[$disk]="shred -n${SHRED_PASSES} -z"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------
# Trap para dejar aviso claro si se interrumpe
# ------------------------------------------------------------------
trap 'log "\nADVERTENCIA: script interrumpido manualmente. Revisá el estado de los discos en curso antes de continuar."; exit 130' INT TERM

# ------------------------------------------------------------------
# Loop principal de borrado
# ------------------------------------------------------------------
for disk in "${disks_to_wipe[@]}"; do
    dev="/dev/$disk"
    log "\n=== Procesando $dev ==="

    # Verificar que no esté montado
    if grep -qs "^${dev}" /proc/mounts || lsblk -no MOUNTPOINT "$dev" | grep -q .; then
        log "[$disk] AVISO: el disco (o alguna partición) figura montado. Desmontando..."
        umount "${dev}"* 2>/dev/null || true
    fi

    tran=$(lsblk -dno TRAN "$dev" | xargs)
    rota=$(lsblk -dno ROTA "$dev" | xargs)

    start_time=$(date)
    ok=1

    if [[ "$tran" == "nvme" ]]; then
        wipe_nvme "$disk" && ok=0
    else
        wipe_ata_secure_erase "$disk"
        rc=$?
        if [[ $rc -eq 0 ]]; then
            ok=0
        elif [[ "$rota" == "0" ]]; then
            # SSD sin secure erase soportado/disponible -> fallback TRIM
            wipe_blkdiscard "$disk" && ok=0
        else
            # HDD sin secure erase soportado -> fallback shred
            wipe_shred "$disk" && ok=0
        fi
    fi

    end_time=$(date)

    if [[ $ok -eq 0 ]]; then
        RESULT[$disk]="OK"
        log "[$disk] Borrado completado correctamente. Método: ${METHOD_USED[$disk]:-desconocido}"
    else
        RESULT[$disk]="FALLÓ"
        METHOD_USED[$disk]="${METHOD_USED[$disk]:-ninguno (todos los métodos fallaron)}"
        log "[$disk] ERROR: no se pudo completar el borrado seguro."
    fi

    {
        echo "Dispositivo: $dev"
        echo "Modelo/Serial: $(lsblk -dno MODEL,SERIAL "$dev" | xargs)"
        echo "Método: ${METHOD_USED[$disk]}"
        echo "Inicio: $start_time"
        echo "Fin: $end_time"
        echo "Resultado: ${RESULT[$disk]}"
        echo "--------------------------------------------------"
    } >> "$REPORT"
done

# ------------------------------------------------------------------
# Resumen final
# ------------------------------------------------------------------
log "\n=== Resumen final ==="
fail_count=0
for disk in "${disks_to_wipe[@]}"; do
    log "  /dev/$disk -> ${RESULT[$disk]} (${METHOD_USED[$disk]:-})"
    [[ "${RESULT[$disk]}" == "FALLÓ" ]] && fail_count=$((fail_count + 1))
done
log "\nCertificado de borrado guardado en: $REPORT"
log "Log completo guardado en: $LOGFILE"

if [[ $fail_count -gt 0 ]]; then
    log "\nATENCIÓN: $fail_count disco(s) no se pudieron borrar correctamente. Revisá el log antes de reiniciar."
    read -r -p "¿Reiniciar de todas formas? (s/N): " reboot_ans
else
    read -r -p "\nTodos los discos se borraron correctamente. ¿Reiniciar ahora? (s/N): " reboot_ans
fi

if [[ "$reboot_ans" =~ ^[sS]$ ]]; then
    log "Reiniciando..."
    reboot
else
    log "Reinicio omitido por el usuario. Script finalizado."
fi
