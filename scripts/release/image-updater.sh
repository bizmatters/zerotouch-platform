#!/bin/bash
# image-updater.sh - Helper for updating Crossplane CRD image fields

# Update image field in any YAML file
update_crossplane_image() {
    local yaml_file="$1"
    
    if [[ ! -f "$yaml_file" ]]; then
        log_error "YAML file not found: $yaml_file"
        return 1
    fi
    
    log_info "Current file:"
    cat "$yaml_file"
    
    # Update image field using sed - find all image: lines and replace with new tag
    log_info "Updating all image references using sed"
    
    # Use sed to replace any line containing "image: ghcr.io/arun4infra/SERVICE_NAME" with the new IMAGE_TAG
    # Extract service name from IMAGE_TAG to match the correct images
    local service_image_base
    service_image_base=$(echo "$IMAGE_TAG" | cut -d':' -f1)
    
    sed -i.bak "s|^\([[:space:]]*\)image: ${service_image_base}[^[:space:]]*|\1image: ${IMAGE_TAG}|" "$yaml_file"
    rm -f "${yaml_file}.bak"
    
    log_info "Updated file:"
    cat "$yaml_file"
    
    log_success "Image updated successfully"
    return 0
}