#!/bin/bash

#############################################
# Script para migrar deployments de OKD a Backstage
# 
# Funciones:
# 1. Lista deployments de namespaces seleccionados
# 2. Agrega labels de Backstage a cada deployment
# 3. Genera catalog-info.yaml para cada uno
#############################################

# === CONFIGURACIÓN ===

# Namespaces a procesar (separados por espacio)
# Puedes usar "all" para todos los namespaces
NAMESPACES="identity-ns bxy-prod-ns endarea-ns"

# Owner por defecto para las entidades de Backstage
DEFAULT_OWNER="lyncorp"

# Directorio donde se guardarán los catalog-info.yaml
OUTPUT_DIR="./backstage-catalog"

# Prefijo para filtrar deployments (opcional, dejar vacío para todos)
# Ejemplo: "app-" solo procesará deployments que empiecen con "app-"
FILTER_PREFIX=""

# Lifecycle por defecto
DEFAULT_LIFECYCLE="production"

# Si es true, aplica los labels. Si es false, solo genera los YAML (modo dry-run)
APPLY_LABELS=true

# === FIN CONFIGURACIÓN ===

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Crear directorio de salida
mkdir -p "$OUTPUT_DIR"

# Archivo consolidado con todas las entidades
CONSOLIDATED_FILE="$OUTPUT_DIR/all-components.yaml"
> "$CONSOLIDATED_FILE"

# Función para normalizar nombres (lowercase, sin caracteres especiales)
normalize_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//'
}

# Función para obtener deployments
get_deployments() {
    local namespace=$1
    
    if [ "$namespace" == "all" ]; then
        oc get deployments -A -o jsonpath='{range .items[*]}{.metadata.namespace},{.metadata.name}{"\n"}{end}'
    else
        oc get deployments -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.namespace},{.metadata.name}{"\n"}{end}'
    fi
}

# Función para agregar labels a un deployment
add_labels_to_deployment() {
    local namespace=$1
    local deployment=$2
    local kubernetes_id=$3
    
    echo -e "${YELLOW}Agregando labels a $deployment en namespace $namespace...${NC}"
    
    if [ "$APPLY_LABELS" = true ]; then
        # Label en el deployment
        oc label deployment "$deployment" -n "$namespace" \
            "backstage.io/kubernetes-id=$kubernetes_id" \
            "app.kubernetes.io/managed-by=backstage" \
            --overwrite
        
        # Label en el pod template
        oc patch deployment "$deployment" -n "$namespace" \
            -p "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"backstage.io/kubernetes-id\":\"$kubernetes_id\"}}}}}"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Labels agregados correctamente${NC}"
        else
            echo -e "${RED}Error al agregar labels${NC}"
        fi
    else
        echo -e "${YELLOW}[DRY-RUN] Se agregarían labels: backstage.io/kubernetes-id=$kubernetes_id${NC}"
    fi
}

# Función para generar catalog-info.yaml
generate_catalog_info() {
    local namespace=$1
    local deployment=$2
    local kubernetes_id=$3
    local owner=$4
    local lifecycle=$5
    
    local output_file="$OUTPUT_DIR/${namespace}-${deployment}.yaml"
    
    cat > "$output_file" << EOF
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: ${kubernetes_id}
  title: ${deployment}
  description: Componente ${deployment} en namespace ${namespace}
  annotations:
    backstage.io/kubernetes-id: ${kubernetes_id}
    backstage.io/kubernetes-namespace: ${namespace}
  tags:
    - kubernetes
    - okd
    - ${namespace}
spec:
  type: service
  lifecycle: ${lifecycle}
  owner: ${owner}
EOF

    echo -e "${GREEN}Generado: $output_file${NC}"
    
    # Agregar al archivo consolidado
    cat "$output_file" >> "$CONSOLIDATED_FILE"
    echo "---" >> "$CONSOLIDATED_FILE"
}

# Función para generar un Location que agrupe todos los componentes
generate_location_file() {
    local location_file="$OUTPUT_DIR/all-locations.yaml"
    
    cat > "$location_file" << EOF
apiVersion: backstage.io/v1alpha1
kind: Location
metadata:
  name: okd-deployments
  description: Todos los deployments importados desde OKD
spec:
  targets:
EOF

    for file in "$OUTPUT_DIR"/*.yaml; do
        if [[ "$file" != *"all-"* ]]; then
            echo "    - ./${file##*/}" >> "$location_file"
        fi
    done
    
    echo -e "${GREEN}Generado archivo de ubicaciones: $location_file${NC}"
}

# Función principal
main() {
    echo "============================================"
    echo "  Migración de Deployments OKD a Backstage"
    echo "============================================"
    echo ""
    
    # Verificar conexión a OKD
    if ! oc whoami &> /dev/null; then
        echo -e "${RED}Error: No estás conectado a OKD. Ejecuta 'oc login' primero.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Conectado a OKD como: $(oc whoami)${NC}"
    echo -e "${GREEN}Cluster: $(oc whoami --show-server)${NC}"
    echo ""
    
    local count=0
    
    # Procesar cada namespace
    for ns in $NAMESPACES; do
        echo ""
        echo "=== Procesando namespace: $ns ==="
        echo ""
        
        # Obtener deployments
        while IFS=',' read -r namespace deployment; do
            # Saltar líneas vacías
            [ -z "$deployment" ] && continue
            
            # Aplicar filtro de prefijo si está configurado
            if [ -n "$FILTER_PREFIX" ]; then
                if [[ ! "$deployment" == "$FILTER_PREFIX"* ]]; then
                    echo -e "${YELLOW}Saltando $deployment (no coincide con filtro)${NC}"
                    continue
                fi
            fi
            
            # Normalizar nombre para kubernetes-id
            local kubernetes_id=$(normalize_name "$deployment")
            
            echo ""
            echo "Procesando: $deployment"
            echo "  Namespace: $namespace"
            echo "  Kubernetes ID: $kubernetes_id"
            
            # Agregar labels
            add_labels_to_deployment "$namespace" "$deployment" "$kubernetes_id"
            
            # Generar catalog-info.yaml
            generate_catalog_info "$namespace" "$deployment" "$kubernetes_id" "$DEFAULT_OWNER" "$DEFAULT_LIFECYCLE"
            
            ((count++))
            
        done < <(get_deployments "$ns")
    done
    
    echo ""
    echo "============================================"
    echo "  Resumen"
    echo "============================================"
    echo ""
    echo -e "${GREEN}Deployments procesados: $count${NC}"
    echo -e "${GREEN}Archivos generados en: $OUTPUT_DIR${NC}"
    echo ""
    
    # Generar archivo de ubicaciones
    generate_location_file
    
    # Mostrar estructura de archivos
    echo "Archivos generados:"
    ls -la "$OUTPUT_DIR"
    
    echo ""
    echo "============================================"
    echo "  Próximos pasos"
    echo "============================================"
    echo ""
    echo "1. Revisa los archivos generados en $OUTPUT_DIR"
    echo "2. Ajusta owners, lifecycles y descripciones según necesites"
    echo "3. Sube los archivos a un repositorio Git"
    echo "4. Registra el archivo 'all-locations.yaml' o 'all-components.yaml' en Backstage"
    echo ""
    
    if [ "$APPLY_LABELS" = false ]; then
        echo -e "${YELLOW}NOTA: Los labels NO fueron aplicados (modo dry-run).${NC}"
        echo -e "${YELLOW}Cambia APPLY_LABELS=true para aplicarlos.${NC}"
    fi
}

# Ejecutar
main
