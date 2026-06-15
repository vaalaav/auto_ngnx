Установщик на VPS:
1. Установить всё
2. Установить/обновить сайт
3. Установить/обновить SSL
4. Установить/обновить CrowdSec
5. Установить/обновить CyberOK Skipa IPs
6. Включить BBR
7. Установить/обновить команду myserverinfo
8. Показать информацию о сервере

Команда для проверки состояния: myserverinfo
1. Вся информация
2. Система (ОС, ядро, CPU, RAM, диск, IP)
3. NGINX
4. Сайт
5. SSL
6. CrowdSec
7. Firewall bouncer
8. CyberOK Skipa IPs
9. BBR
   
Установка: curl -fsSL https://raw.githubusercontent.com/vaalaav/auto_ngnx/main/vps_setup.sh -o vps_setup.sh && sudo bash vps_setup.sh
