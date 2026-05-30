# AXI_LITE_slave_with_UVM

AXI-Lite 슬레이브 RTL에 대한 UVM 기반 검증 환경 구현 프로젝트.

## 구성

| 파일 | 설명 |
|---|---|
| `AXI_LITE_slave.sv` | DUT: 4개 레지스터(CTRL/STATUS/CONFIG0/CONFIG1) AXI-Lite 슬레이브 |
| `tb_axi_lite_uvm.sv` | UVM 검증환경 (드라이버/모니터/스코어보드/커버리지) |

## UVM 환경 구성

```
axi_test
  └── axi_env
        ├── axi_agent
        │     ├── axi_wr_driver   (AW+W 채널 구동)
        │     ├── axi_rd_driver   (AR+R 채널 구동)
        │     ├── axi_wr_monitor
        │     └── axi_rd_monitor
        ├── axi_scoreboard  (Shadow register 기반 검증)
        └── axi_coverage    (주소×WSTRB 크로스 커버리지)
```

## 주요 설계 포인트

- **Shadow Register**: 스코어보드가 DUT 내부 레지스터를 소프트웨어로 추적하여 RDATA 비교
- **STATUS(RO) 처리**: addr[3:2]=01 레지스터는 shadow 업데이트 제외
- **addr_queue_obj**: wr→rd 드라이버 간 쓰기 주소 공유 (config_db로 전달)
- **커버리지**: 4개 레지스터 × WSTRB(0000/1111/기타) 크로스 커버리지

## 시뮬레이션

EDA Playground (Aldec Riviera-PRO 2025.04 + UVM 1.2)  
▶ https://www.edaplayground.com/x/JdY6
