import dns.resolver
import requests
import csv

# Danh sách các domain cần kiểm tra
domain_list = ["domain1.vnn.vn", "123.domain1.vnn.vn", "erw.domain1.vnn.vn"]

# Tên file kết quả
output_file = "domain_check_results.csv"

# Hàm kiểm tra trạng thái HTTP của domain
def check_http_status(domain):
    try:
        response = requests.get(f"http://{domain}", timeout=5)
        return response.status_code
    except requests.RequestException:
        return "Không kết nối được"

# Hàm lấy IP của domain qua DNS server 8.8.8.8
def get_ip_via_dns(domain):
    try:
        resolver = dns.resolver.Resolver()
        resolver.nameservers = ['8.8.8.8']
        answer = resolver.resolve(domain, 'A')
        return answer[0].to_text()  # Lấy địa chỉ IP từ kết quả trả về
    except (dns.resolver.NoAnswer, dns.resolver.NXDOMAIN, dns.resolver.Timeout):
        return "Không tìm thấy IP hoặc truy vấn thất bại"

# Thực hiện kiểm tra các domain và lưu kết quả vào file CSV
with open(output_file, mode="w", newline='', encoding="utf-8") as file:
    writer = csv.writer(file)
    writer.writerow(["Domain", "Địa chỉ IP", "Trạng thái HTTP"])

    for domain in domain_list:
        ip = get_ip_via_dns(domain)
        http_status = check_http_status(domain)
        writer.writerow([domain, ip, http_status])
        print(f"Đã kiểm tra: {domain}, IP: {ip}, Trạng thái: {http_status}")

print(f"Kết quả đã được lưu vào file {output_file}")
