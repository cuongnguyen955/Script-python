import requests
import csv
import subprocess

# Cấu hình API
api_key = "Thay_bang_API_key_cua_ban"  # Thay bằng API key của bạn, con cua minh luu trong keepass roi :D
base_url = "https://api.securitytrails.com/v1/domain"

# Domain chính cần kiểm tra
main_domain = "udn.vn"

# Tên file kết quả
output_file = "subdomain_check_results.csv"

# Máy chủ DNS để thực hiện truy vấn
dns_server = "8.8.8.8"  # Thay đổi máy chủ DNS tùy ý (ví dụ: 1.1.1.1 hoặc 8.8.4.4)

# Hàm lấy danh sách subdomain từ SecurityTrails API
def get_subdomains(domain):
    headers = {
        "APIKEY": api_key
    }
    try:
        response = requests.get(f"{base_url}/{domain}/subdomains", headers=headers)
        if response.status_code == 200:
            data = response.json()
            return [f"{sub}.{domain}" for sub in data.get("subdomains", [])]
        else:
            print(f"Lỗi khi truy vấn API: {response.status_code}")
            return []
    except requests.RequestException as e:
        print(f"Lỗi kết nối đến API: {e}")
        return []

# Hàm kiểm tra trạng thái HTTP của subdomain
def check_http_status(domain):
    try:
        response = requests.get(f"http://{domain}", timeout=5)
        return response.status_code
    except requests.RequestException:
        return "Không kết nối được"

# Hàm lấy địa chỉ IP của subdomain qua nslookup với máy chủ DNS tùy chọn
def get_ip_nslookup(domain, dns_server="8.8.8.8"):
    try:
        result = subprocess.run(["nslookup", domain, dns_server], capture_output=True, text=True)
        output = result.stdout
        # Tìm địa chỉ IP của subdomain, bỏ qua dòng đầu tiên có chứa "Address:" (thường là của DNS server)
        found_first_address = False
        for line in output.splitlines():
            if "Address:" in line:
                if not found_first_address:
                    # Bỏ qua dòng Address đầu tiên (IP của DNS server)
                    found_first_address = True
                    continue
                # Trả về IP của subdomain
                return line.split("Address:")[-1].strip()
        return "Không tìm thấy IP"
    except Exception as e:
        return "Lỗi khi chạy nslookup"

# Lấy danh sách subdomain và lưu kết quả vào file CSV
subdomains = get_subdomains(main_domain)
with open(output_file, mode="w", newline='', encoding="utf-8") as file:
    writer = csv.writer(file)
    writer.writerow(["Subdomain", "Địa chỉ IP", "Trạng thái HTTP"])

    for subdomain in subdomains:
        ip_address = get_ip_nslookup(subdomain, dns_server)
        http_status = check_http_status(subdomain) if ip_address != "Không tìm thấy IP" else "Không xác định"
        writer.writerow([subdomain, ip_address, http_status])
        print(f"Đã kiểm tra: {subdomain}, IP: {ip_address}, Trạng thái: {http_status}")

print(f"Kết quả đã được lưu vào file {output_file}")
