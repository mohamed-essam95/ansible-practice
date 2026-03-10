#!/bin/bash

set -e

NUM_CONTAINERS=3
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_DIR="${SCRIPT_DIR}/ansible_ssh_keys"
PRIVATE_KEY="${SSH_DIR}/ansible_key"
PUBLIC_KEY="${SSH_DIR}/ansible_key.pub"
NETWORK_NAME="ansible_network"
CONTAINER_PREFIX="ansible_node"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

function print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

function print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

function print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

function cleanup() {
    print_info "Cleaning up Ansible environment..."
    
    # Stop and remove containers
    for i in {1..3}; do
        container_name="${CONTAINER_PREFIX}_${i}"
        if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
            print_info "Removing container: ${container_name}"
            docker rm -f "${container_name}" > /dev/null 2>&1
        fi
    done
    
    # Remove network
    if docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
        print_info "Removing network: ${NETWORK_NAME}"
        docker network rm "${NETWORK_NAME}" > /dev/null 2>&1
    fi
    
    # Remove SSH keys
    if [ -d "${SSH_DIR}" ]; then
        print_info "Removing SSH keys directory: ${SSH_DIR}"
        rm -rf "${SSH_DIR}"
    fi
    
    print_success "Cleanup completed!"
}

function setup_environment() {
    print_info "Setting up Ansible-ready environment..."
    
    # Create SSH keys directory
    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"
    
    # Generate SSH key pair if not exists
    if [ ! -f "${PRIVATE_KEY}" ]; then
        print_info "Generating SSH key pair..."
        ssh-keygen -t rsa -b 4096 -f "${PRIVATE_KEY}" -N "" -C "ansible@docker"
        chmod 600 "${PRIVATE_KEY}"
        chmod 644 "${PUBLIC_KEY}"
        print_success "SSH keys generated"
    else
        print_warning "SSH keys already exist, reusing them"
    fi
    
    # Create Docker network
    if ! docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
        print_info "Creating Docker network: ${NETWORK_NAME}"
        docker network create "${NETWORK_NAME}" > /dev/null
        print_success "Network created"
    else
        print_warning "Network ${NETWORK_NAME} already exists"
    fi
    
    # Read public key content
    PUBLIC_KEY_CONTENT=$(cat "${PUBLIC_KEY}")
    
    # Create Dockerfile for SSH-enabled container
    print_info "Creating Dockerfile..."
    cat > "${SSH_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y openssh-server sudo python3 pip curl vim cron systemctl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    apt update -y

RUN mkdir /var/run/sshd

# Create ansible user with sudo privileges
RUN useradd -m -s /bin/bash ansible && \
    echo "ansible:ansible" | chpasswd && \
    usermod -aG sudo ansible && \
    echo "ansible ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Configure SSH
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

# Setup SSH directory for ansible user
RUN mkdir -p /home/ansible/.ssh && \
    chmod 700 /home/ansible/.ssh && \
    chown ansible:ansible /home/ansible/.ssh

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D"]
EOF
    
    # Build Docker image
    print_info "Building Docker image..."
    docker build -t ansible-node "${SSH_DIR}" > /dev/null
    print_success "Docker image built"
    
    # Start containers
    print_info "Starting 3 Docker containers..."
    for i in $(seq 1 ${NUM_CONTAINERS}); do
        container_name="${CONTAINER_PREFIX}_${i}"
        print_info "Starting container: ${container_name}"
        
        docker run -d \
            --name "${container_name}" \
            --network "${NETWORK_NAME}" \
            --hostname "${container_name}" \
            ansible-node > /dev/null
        
        # Copy public key to container
        docker exec "${container_name}" bash -c "echo '${PUBLIC_KEY_CONTENT}' > /home/ansible/.ssh/authorized_keys"
        docker exec "${container_name}" bash -c "chmod 600 /home/ansible/.ssh/authorized_keys"
        docker exec "${container_name}" bash -c "chown ansible:ansible /home/ansible/.ssh/authorized_keys"
        
        print_success "Container ${container_name} started"
    done
    
    # Wait a moment for containers to fully start
    sleep 2
    
    # Display information
    echo ""
    echo "======================================"
    print_success "Ansible Environment Ready!"
    echo "======================================"
    echo ""
    echo -e "${GREEN}Private Key Path:${NC}"
    echo "  ${PRIVATE_KEY}"
    echo ""
    echo -e "${GREEN}Container Details:${NC}"
    echo ""
    
    for i in $(seq 1 ${NUM_CONTAINERS}); do
        container_name="${CONTAINER_PREFIX}_${i}"
        ip_address=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${container_name}")
        echo -e "  ${BLUE}Container ${i}:${NC} ${container_name}"
        echo -e "    IP Address: ${ip_address}"
        echo -e "    SSH Command: ssh -i ${PRIVATE_KEY} ansible@${ip_address}"
        echo ""
    done
    
    echo -e "${GREEN}Ansible Inventory Example:${NC}"
    echo ""
    echo "[docker_nodes]"
    for i in $(seq 1 ${NUM_CONTAINERS}); do
        container_name="${CONTAINER_PREFIX}_${i}"
        ip_address=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${container_name}")
        echo "${container_name} ansible_host=${ip_address} ansible_user=ansible ansible_ssh_private_key_file=${PRIVATE_KEY}"
    done
    echo ""
    echo -e "${YELLOW}To destroy this environment, run:${NC}"
    echo "  $0 destroy"
    echo ""
}

# Main script logic
case "${1:-}" in
    destroy)
        cleanup
        ;;
    "")
        setup_environment
        ;;
    *)
        print_error "Unknown argument: $1"
        echo "Usage: $0 [destroy]"
        echo "  (no args) - Setup Ansible environment"
        echo "  destroy   - Destroy Ansible environment"
        exit 1
        ;;
esac