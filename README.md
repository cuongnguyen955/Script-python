# Script python
 Tong hop cac script python hay dung

#
# File nslookup_domains.py
 cai dat thu vien
 pip install requests
 pip install dnspython
 
  dien danh sach domain can tim ip o dong 
 domain_list = ["domain1.vnn.vn", "123.domain1.vnn.vn", "erw.domain1.vnn.vn"]

Giải thích:
Danh sách domain: Bạn thay domain_list bằng danh sách domain của doanh nghiệp.
Hàm check_http_status: Gửi yêu cầu HTTP đến từng domain và trả về mã trạng thái HTTP.
Hàm get_ip: Lấy địa chỉ IP của domain.
File CSV: Tạo và ghi kết quả vào file domain_check_results.csv gồm các cột: Domain, Địa chỉ IP, và Trạng thái HTTP.

#
# File Find_all_sub_domain.py 
 pip install requests
 pip install dnspython
 
Để tìm các subdomain của một tên miền như vnn.vn một cách nhanh chóng và hiệu quả hơn, bạn có thể sử dụng các API tra cứu DNS có hỗ trợ tìm kiếm subdomain, chẳng hạn như API của SecurityTrails, VirusTotal, hoặc DNSDumpster.

Dưới đây là một ví dụ sử dụng API của SecurityTrails để liệt kê tất cả các subdomain của tên miền vnn.vn. Để sử dụng API này, bạn sẽ cần đăng ký tài khoản trên SecurityTrails và lấy API key.

Lưu ý rằng một số API cung cấp dịch vụ miễn phí với hạn mức nhất định hoặc yêu cầu thanh toán. Đảm bảo tuân thủ các điều khoản sử dụng của API.

Mã Python Sử Dụng SecurityTrails API
 Sau do thay API Key tai dong
 api_key = "Thay_bang_API_key_cua_ban"  # Thay bằng API key của bạn
 
 Thay vnn.vn bang domain can tim cac subdomain
 main_domain = "vnn.vn"