#!/bin/bash
# MediaCMS Auto Install Script for Ubuntu - Enhanced
# Sử dụng script install.sh chính thức + các tùy chọn bổ sung

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then 
    print_error "Vui lòng chạy với quyền sudo"
    exit 1
fi

# Kiểm tra Ubuntu
if ! grep -q "Ubuntu" /etc/os-release; then
    print_error "Script này chỉ hỗ trợ Ubuntu"
    exit 1
fi

echo "========================================"
echo "  MediaCMS Auto Install - Enhanced"
echo "========================================"

# Nhập thông tin cơ bản
while true; do
    read -p "Domain cho MediaCMS (vd: media.example.com): " DOMAIN
    read -p "Email admin: " ADMIN_EMAIL
    read -p "Username admin mới: " ADMIN_USER
    read -s -p "Password admin mới: " ADMIN_PASS
    echo ""
    
    if [ -z "$DOMAIN" ] || [ -z "$ADMIN_EMAIL" ] || [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
        print_error "Vui lòng nhập đầy đủ thông tin"
    else
        break
    fi
done

# Tùy chọn bảo mật
echo ""
print_info "Tùy chọn bảo mật:"
read -p "Tắt đăng ký tự do? (Y/n): " DISABLE_REGISTER
read -p "Chỉ admin upload được? (y/N): " ADMIN_ONLY_UPLOAD
read -p "Cần approve trước khi hiển thị? (y/N): " REQUIRE_APPROVAL

# Xác nhận
echo ""
print_warning "Sẽ cài MediaCMS với:"
echo "Domain: $DOMAIN"
echo "Email: $ADMIN_EMAIL"
echo "Admin user: $ADMIN_USER"
echo "Tắt đăng ký: ${DISABLE_REGISTER:-Y}"
echo "Admin upload only: ${ADMIN_ONLY_UPLOAD:-N}"
echo "Cần approval: ${REQUIRE_APPROVAL:-N}"
echo ""
read -p "Tiếp tục? (y/n): " confirm
[ "$confirm" != "y" ] && exit 0

# Cài đặt dependencies cơ bản
print_info "Đang cài đặt dependencies..."
apt install -y git curl wget nano
print_success "Dependencies cơ bản đã được cài đặt"

# Tạo thư mục và clone MediaCMS
print_info "Đang tải MediaCMS..."
mkdir -p /home/mediacms.io
cd /home/mediacms.io

if [ ! -d "mediacms" ]; then
    git clone https://github.com/mediacms-io/mediacms
    print_success "MediaCMS đã được tải về"
else
    print_warning "MediaCMS đã tồn tại, đang cập nhật..."
    cd mediacms && git pull && cd ..
fi

# Chuyển vào thư mục MediaCMS
cd /home/mediacms.io/mediacms/

# Chạy script install.sh chính thức
print_info "Đang chạy script cài đặt chính thức..."
bash ./install.sh

print_success "Script cài đặt chính thức hoàn tất"

# Đợi một chút để services khởi động
print_info "Đợi services khởi động..."
sleep 10

# Activate virtual environment và cấu hình
print_info "Đang cấu hình MediaCMS..."
cd /home/mediacms.io/mediacms/

# Activate virtual environment
source /home/mediacms.io/bin/activate

# Tạo backup của local_settings.py
cp cms/local_settings.py cms/local_settings.py.backup

# Cập nhật cấu hình với domain
print_info "Cập nhật cấu hình domain..."
cat >> cms/local_settings.py << EOF

# Custom configurations
FRONTEND_HOST = 'https://$DOMAIN'
SSL_FRONTEND_HOST = 'https://$DOMAIN'
ALLOWED_HOSTS = ['$DOMAIN', 'www.$DOMAIN', 'localhost', '127.0.0.1']

# Email settings  
DEFAULT_FROM_EMAIL = '$ADMIN_EMAIL'
EOF

# Thêm cấu hình bảo mật
if [[ "${DISABLE_REGISTER:-Y}" =~ ^[Yy]$ ]]; then
    echo "USERS_CAN_SELF_REGISTER = False" >> cms/local_settings.py
    print_success "Đã tắt đăng ký tự do"
fi

if [[ "$ADMIN_ONLY_UPLOAD" =~ ^[Yy]$ ]]; then
    echo "USERS_CAN_ADD_MEDIA = False" >> cms/local_settings.py
    print_success "Chỉ admin mới upload được"
fi

if [[ "$REQUIRE_APPROVAL" =~ ^[Yy]$ ]]; then
    echo "MEDIA_IS_REVIEWED = False" >> cms/local_settings.py
    print_success "Media cần approve trước khi hiển thị"
fi

# Tạo superuser mới
print_info "Đang tạo admin user mới..."
echo "from django.contrib.auth import get_user_model; User = get_user_model(); User.objects.create_superuser('$ADMIN_USER', '$ADMIN_EMAIL', '$ADMIN_PASS') if not User.objects.filter(username='$ADMIN_USER').exists() else print('User đã tồn tại')" | python manage.py shell

print_success "Admin user '$ADMIN_USER' đã được tạo"

# Đổi password cho user admin mặc định (nếu tồn tại)
print_info "Đang vô hiệu hóa user admin mặc định..."
echo "from django.contrib.auth import get_user_model; User = get_user_model(); u = User.objects.filter(username='admin').first(); u.set_unusable_password(); u.save() if u else None" | python manage.py shell

# Cập nhật NGINX config với domain mới
print_info "Cập nhật NGINX config..."
NGINX_CONFIG="/etc/nginx/sites-available/mediacms.io"
if [ -f "$NGINX_CONFIG" ]; then
    # Backup original nginx config
    cp "$NGINX_CONFIG" "$NGINX_CONFIG.backup"
    
    # Thay thế domain trong nginx config
    sed -i "s/server_name .*/server_name $DOMAIN;/g" "$NGINX_CONFIG"
    
    # Test nginx config
    if nginx -t; then
        print_success "NGINX config đã được cập nhật"
    else
        print_error "NGINX config lỗi, đang restore..."
        cp "$NGINX_CONFIG.backup" "$NGINX_CONFIG"
    fi
fi

# Restart tất cả services
print_info "Đang restart services..."
systemctl restart mediacms celery_long celery_short nginx

# Đợi services restart
sleep 5

# Lấy SSL certificate
print_info "Đang lấy SSL certificate..."
if command -v certbot &> /dev/null; then
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$ADMIN_EMAIL" --redirect || {
        print_warning "Không lấy được SSL certificate. Chạy manual sau:"
        print_warning "sudo certbot --nginx -d $DOMAIN"
    }
else
    print_warning "Certbot chưa được cài. Cài đặt SSL manual:"
    print_warning "sudo apt install certbot python3-certbot-nginx"
    print_warning "sudo certbot --nginx -d $DOMAIN"
fi

# Kiểm tra services cuối cùng
print_info "Kiểm tra services..."
services=("nginx" "mediacms" "celery_long" "celery_short")

for service in "${services[@]}"; do
    if systemctl is-active --quiet "$service"; then
        print_success "$service đang chạy"
    else
        print_error "$service không chạy - thử restart: sudo systemctl restart $service"
    fi
done

# Kiểm tra kết nối
print_info "Kiểm tra kết nối..."
sleep 5
if curl -s -o /dev/null -w "%{http_code}" "http://localhost" | grep -q "200\|302\|301"; then
    print_success "MediaCMS đang hoạt động"
else
    print_warning "MediaCMS có thể chưa sẵn sàng, hãy đợi thêm vài phút"
fi

# Tạo script tiện ích
print_info "Tạo script tiện ích..."
cat > /usr/local/bin/mediacms-manage << 'SCRIPT_EOF'
#!/bin/bash
# MediaCMS Management Script

cd /home/mediacms.io/mediacms/
source /home/mediacms.io/bin/activate

case "$1" in
    "restart")
        echo "Restarting MediaCMS services..."
        sudo systemctl restart mediacms celery_long celery_short nginx
        ;;
    "logs")
        echo "Showing MediaCMS logs..."
        sudo journalctl -f -u mediacms
        ;;
    "status")
        echo "MediaCMS services status:"
        sudo systemctl status mediacms celery_long celery_short nginx
        ;;
    "shell")
        echo "Opening Django shell..."
        python manage.py shell
        ;;
    "createuser")
        echo "Creating new superuser..."
        python manage.py createsuperuser
        ;;
    *)
        echo "MediaCMS Management Commands:"
        echo "  mediacms-manage restart   - Restart all services"
        echo "  mediacms-manage logs      - Show logs"
        echo "  mediacms-manage status    - Check services status"
        echo "  mediacms-manage shell     - Django shell"
        echo "  mediacms-manage createuser - Create superuser"
        ;;
esac
SCRIPT_EOF

chmod +x /usr/local/bin/mediacms-manage
print_success "Script tiện ích đã được tạo: mediacms-manage"

# Hoàn tất
echo ""
echo "========================================"
print_success "Cài đặt MediaCMS hoàn tất! 🎉"
echo "========================================"
echo ""
echo "Thông tin truy cập:"
echo "URL: https://$DOMAIN (hoặc http://your-server-ip)"
echo "Admin: $ADMIN_USER"
echo "Email: $ADMIN_EMAIL"
echo ""
print_warning "Cấu hình đã áp dụng:"
echo "✓ Tắt đăng ký tự do: ${DISABLE_REGISTER:-Y}"
echo "✓ Admin upload only: ${ADMIN_ONLY_UPLOAD:-N}"
echo "✓ Cần approval: ${REQUIRE_APPROVAL:-N}"
echo ""
print_info "Commands hữu ích:"
echo "mediacms-manage restart   # Restart services"
echo "mediacms-manage logs      # Xem logs"
echo "mediacms-manage status    # Kiểm tra status"
echo "mediacms-manage createuser # Tạo user mới"
echo ""
print_warning "Nhớ làm:"
echo "1. Cấu hình DNS A record: $DOMAIN → $(hostname -I | awk '{print $1}')"
echo "2. Cấu hình email SMTP trong local_settings.py"
echo "3. Kiểm tra firewall (port 80, 443)"
echo "4. Backup file: /home/mediacms.io/mediacms/cms/local_settings.py"
echo ""
# Menu tùy chọn sau cài đặt
post_install_menu() {
    echo ""
    echo "========================================"
    echo "  Menu Tùy Chỉnh MediaCMS"
    echo "========================================"
    echo "1. Khóa/Mở đăng ký tài khoản"
    echo "2. Thay đổi mật khẩu admin"
    echo "3. Tạo user mới"
    echo "4. Xem danh sách users"
    echo "5. Thoát"
    echo "========================================"
}

# Function xử lý từng lựa chọn
handle_menu_choice() {
    cd /home/mediacms.io/mediacms/
    source /home/mediacms.io/bin/activate
    
    case $1 in
        1)
            echo ""
            echo "Trạng thái đăng ký hiện tại:"
            python manage.py shell -c "
from cms.local_settings import USERS_CAN_SELF_REGISTER
print('Cho phép đăng ký:', USERS_CAN_SELF_REGISTER)
" 2>/dev/null || echo "Hiện tại: Cho phép đăng ký"
            
            echo ""
            read -p "Khóa đăng ký? (y/N): " lock_register
            
            if [[ "$lock_register" =~ ^[Yy]$ ]]; then
                # Xóa dòng cũ nếu có và thêm dòng mới
                sed -i '/USERS_CAN_SELF_REGISTER/d' cms/local_settings.py
                echo "USERS_CAN_SELF_REGISTER = False" >> cms/local_settings.py
                print_success "Đã khóa đăng ký tài khoản"
            else
                sed -i '/USERS_CAN_SELF_REGISTER/d' cms/local_settings.py
                echo "USERS_CAN_SELF_REGISTER = True" >> cms/local_settings.py
                print_success "Đã mở đăng ký tài khoản"
            fi
            
            systemctl restart mediacms
            print_info "Đã restart MediaCMS"
            ;;
        2)
            echo ""
            read -p "Username cần đổi password: " username
            
            if [ -z "$username" ]; then
                print_error "Vui lòng nhập username"
                return
            fi
            
            # Kiểm tra user có tồn tại không
            user_exists=$(python manage.py shell -c "
from django.contrib.auth import get_user_model
User = get_user_model()
print(User.objects.filter(username='$username').exists())
" 2>/dev/null)
            
            if [[ "$user_exists" == *"True"* ]]; then
                python manage.py changepassword "$username"
                print_success "Đã đổi password cho $username"
            else
                print_error "User '$username' không tồn tại"
            fi
            ;;
        3)
            echo ""
            read -p "Username mới: " new_username
            read -p "Email: " new_email
            read -p "Là superuser? (y/N): " is_superuser
            read -s -p "Password: " new_password
            echo ""
            
            if [ -z "$new_username" ] || [ -z "$new_email" ] || [ -z "$new_password" ]; then
                print_error "Vui lòng nhập đầy đủ thông tin"
                return
            fi
            
            if [[ "$is_superuser" =~ ^[Yy]$ ]]; then
                python manage.py shell -c "
from django.contrib.auth import get_user_model
User = get_user_model()
if not User.objects.filter(username='$new_username').exists():
    User.objects.create_superuser('$new_username', '$new_email', '$new_password')
    print('Superuser created successfully')
else:
    print('User already exists')
"
                print_success "Đã tạo superuser '$new_username'"
            else
                python manage.py shell -c "
from django.contrib.auth import get_user_model
User = get_user_model()
if not User.objects.filter(username='$new_username').exists():
    User.objects.create_user('$new_username', '$new_email', '$new_password')
    print('User created successfully')
else:
    print('User already exists')
"
                print_success "Đã tạo user '$new_username'"
            fi
            ;;
        4)
            echo ""
            print_info "Danh sách users trong hệ thống:"
            python manage.py shell -c "
from django.contrib.auth import get_user_model
User = get_user_model()
users = User.objects.all()
for user in users:
    status = 'Superuser' if user.is_superuser else 'User'
    active = 'Active' if user.is_active else 'Inactive'
    print(f'- {user.username} ({user.email}) - {status} - {active}')
"
            ;;
        5)
            print_success "Thoát menu. Chúc huynh dùng vui vẻ! 😄"
            return 1
            ;;
        *)
            print_error "Lựa chọn không hợp lệ"
            ;;
    esac
    return 0
}

# Chạy menu post-install
print_info "Khởi chạy menu tùy chỉnh..."
while true; do
    post_install_menu
    read -p "Chọn (1-5): " choice
    
    if ! handle_menu_choice "$choice"; then
        break
    fi
    
    echo ""
    read -p "Nhấn Enter để tiếp tục..." dummy
done
