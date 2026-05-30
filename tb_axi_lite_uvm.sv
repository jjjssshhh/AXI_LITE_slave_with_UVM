// Code your testbench here
// or browse Examples

`include "uvm_macros.svh"

//==============================================================================
// 인터페이스 : dut_if
// 기      능 : DUT(my_AXI_LITE_slave)와 UVM 환경을 연결하는 가상 인터페이스.
//              ACLK을 포트로 받아 모든 드라이버/모니터가 동일 클럭을 참조.
//==============================================================================
interface dut_if(input logic ACLK);
  logic [3:0]  AWADDR;
  logic [31:0] WDATA;
  logic [3:0]  WSTRB;
  logic [3:0]  ARADDR;
  logic [31:0] RDATA;
  logic AWVALID;
  logic BVALID;
  logic BREADY;
  logic WVALID;
  logic AWREADY;
  logic WREADY;
  logic ARVALID;
  logic RVALID;
  logic ARREADY;
  logic RREADY;
endinterface

//==============================================================================
// 패키지 : axi_lite_slave
// 기   능 : AXI-Lite 슬레이브 UVM 검증 환경 전체를 하나의 패키지로 구성.
//
// 계층 구조:
//   axi_test
//     └── axi_env
//           ├── axi_agent
//           │     ├── axi_wr_driver    ── wr_seqr ── axi_wr_sequence
//           │     ├── axi_rd_driver    ── rd_seqr ── axi_rd_sequence
//           │     ├── axi_wr_monitor   ──┐
//           │     └── axi_rd_monitor   ──┤
//           ├── axi_scoreboard  ←────────┤ (analysis port 연결)
//           └── axi_coverage    ←────────┘
//
// 검증 전략:
//   1. axi_wr_driver  : AXI-Lite 쓰기 프로토콜(AW+W 채널) 구동
//   2. axi_rd_driver  : 쓰기된 주소를 순서대로 읽기(AR+R 채널) 구동
//   3. axi_scoreboard : Shadow register로 WDATA를 추적하고 RDATA와 비교
//   4. axi_coverage   : 모든 레지스터 주소·WSTRB 조합 커버리지 수집
//==============================================================================
package axi_lite_slave;
  import uvm_pkg::*;

  //============================================================================
  // 클래스 : axi_item (uvm_sequence_item)
  // 기  능 : AXI-Lite 트랜잭션 하나를 표현하는 데이터 오브젝트.
  //          쓰기(awaddr, wdata, wstrb)와 읽기(araddr, rdata)를 하나의
  //          item으로 통합하여 wr/rd 시퀀스에서 공용으로 사용.
  //
  // rand 제약:
  //   awaddr, wdata, wstrb, araddr은 randomize() 대상.
  //   rdata는 DUT에서 읽어온 값이므로 rand 제외.
  //============================================================================
  class axi_item extends uvm_sequence_item;

    rand bit  [3:0]  awaddr;
    rand bit  [31:0] wdata;
    rand bit  [3:0]  wstrb;
    rand bit  [3:0]  araddr;
         bit  [31:0] rdata;   // DUT 읽기 결과 (non-rand)

    `uvm_object_utils_begin(axi_item)
    `uvm_field_int(awaddr, UVM_ALL_ON)
    `uvm_field_int(wdata,  UVM_ALL_ON)
    `uvm_field_int(wstrb,  UVM_ALL_ON)
    `uvm_field_int(araddr, UVM_ALL_ON)
    `uvm_field_int(rdata,  UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "axi_item");
      super.new(name);
    endfunction

  endclass

  //============================================================================
  // 클래스 : addr_queue_obj (uvm_object)
  // 기  능 : axi_wr_driver가 기록한 AWADDR을 axi_rd_driver가 순서대로
  //          읽어갈 수 있도록 공유하는 큐 오브젝트.
  //
  // 공유 방식:
  //   axi_test의 build_phase에서 생성 후 uvm_config_db로 등록.
  //   wr_driver: push_back(awaddr) → rd_driver: pop_front()
  //   → 쓰기한 주소와 같은 주소를 읽어 데이터 일관성 검증.
  //============================================================================
  class addr_queue_obj extends uvm_object;
    `uvm_object_utils(addr_queue_obj)
    bit [3:0] queue[$];

    function new(string name = "addr_queue_obj");
      super.new(name);
    endfunction
  endclass


  //============================================================================
  // 클래스 : axi_wr_driver (uvm_driver)
  // 기  능 : AXI-Lite 쓰기 프로토콜을 구동하는 드라이버 (마스터 역할).
  //
  // 프로토콜 동작 순서:
  //   1. AWVALID=1, WVALID=1, AWADDR, WDATA, WSTRB 설정 (AW+W 채널 동시 인가)
  //   2. BVALID 대기 (슬레이브 쓰기 완료 응답)
  //   3. BREADY=1 인가 (마스터가 응답 수신)
  //   4. 다음 클럭에서 BREADY=0, AWVALID=0, WVALID=0 (핸드쉐이크 해제)
  //
  // addr_q: 쓰기한 AWADDR을 큐에 push → rd_driver가 같은 주소를 읽는 데 사용.
  //
  // item_done(a_item): 시퀀스의 get_response()가 블로킹 해제되도록
  //                    item 참조를 반환. finish_item 이후 시퀀스가 재개됨.
  //============================================================================
  class axi_wr_driver extends uvm_driver #(axi_item);
    `uvm_component_utils(axi_wr_driver)

    virtual dut_if _if;
    axi_item       a_item;
    addr_queue_obj addr_q;

    function new(string name = "axi_wr_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual dut_if)::get(this, "", "dut_if", _if))
        `uvm_fatal("fatal", "config_db: dut_if get failed")
      if(!uvm_config_db#(addr_queue_obj)::get(this, "", "addr_q", addr_q))
        `uvm_fatal("fatal", "config_db: addr_q get failed")
    endfunction

    virtual function void connect_phase(uvm_phase phase);
    endfunction

    virtual task run_phase(uvm_phase phase);
      forever begin
        seq_item_port.get_next_item(a_item);

        // AW + W 채널 동시 인가
        _if.AWVALID <= 1; _if.WVALID <= 1;
        _if.AWADDR  <= a_item.awaddr;
        _if.WDATA   <= a_item.wdata;
        _if.WSTRB   <= a_item.wstrb;
        addr_q.queue.push_back(a_item.awaddr);  // rd_driver 공유 큐에 주소 저장

        @(posedge _if.ACLK);
        wait(_if.BVALID);               // 슬레이브 쓰기 완료 대기

        _if.BREADY <= 1;                // B 채널 핸드쉐이크
        @(posedge _if.ACLK);
        _if.BREADY  <= 0;
        _if.AWVALID <= 0; _if.WVALID <= 0;

        seq_item_port.item_done(a_item); // 시퀀스의 get_response() 언블록
      end
    endtask

  endclass


  //============================================================================
  // 클래스 : axi_rd_driver (uvm_driver)
  // 기  능 : AXI-Lite 읽기 프로토콜을 구동하는 드라이버 (마스터 역할).
  //
  // 프로토콜 동작 순서:
  //   1. addr_q에 주소가 쌓일 때까지 대기 (wr_driver와 동기)
  //   2. ARVALID=1, ARADDR 설정 (AR 채널 인가)
  //   3. ARREADY 대기 (슬레이브 주소 수신 확인)
  //   4. RVALID 대기 후 RDATA 캡처
  //   5. RREADY=1 인가 (마스터가 데이터 수신 완료)
  //
  // item_done(a_item): rdata가 채워진 item을 시퀀스로 반환.
  //                    시퀀스에서 get_response()로 읽기 결과를 수신 가능.
  //============================================================================
  class axi_rd_driver extends uvm_driver #(axi_item);
    `uvm_component_utils(axi_rd_driver)

    virtual dut_if _if;
    axi_item       a_item;
    addr_queue_obj addr_q;

    function new(string name = "axi_rd_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual dut_if)::get(this, "", "dut_if", _if))
        `uvm_fatal("fatal", "config_db: dut_if get failed")
      if(!uvm_config_db#(addr_queue_obj)::get(this, "", "addr_q", addr_q))
        `uvm_fatal("fatal", "config_db: addr_q get failed")
    endfunction

    virtual task run_phase(uvm_phase phase);
      forever begin
        seq_item_port.get_next_item(a_item);

        wait(addr_q.queue.size() > 0);       // 쓰기 주소가 준비될 때까지 대기
        _if.ARVALID = 1;
        _if.ARADDR  = addr_q.queue.pop_front(); // 쓰기한 주소와 동일한 주소 읽기

        @(posedge _if.ACLK);
        wait(_if.ARREADY);     // 슬레이브 AR 채널 수신 확인
        wait(_if.RVALID);      // 슬레이브 읽기 데이터 준비 대기

        a_item.rdata = _if.RDATA; // 읽기 결과 캡처

        @(posedge _if.ACLK);
        _if.ARVALID = 0;
        _if.RREADY  = 1;       // R 채널 핸드쉐이크
        @(posedge _if.ACLK);
        _if.RREADY  = 0;

        seq_item_port.item_done(a_item); // rdata가 채워진 item 반환
      end
    endtask

  endclass


  //============================================================================
  // 클래스 : axi_wr_monitor (uvm_monitor)
  // 기  능 : AXI-Lite 쓰기 트랜잭션을 패시브하게 관측하여 analysis port로 전달.
  //
  // 관측 조건: AWVALID & WVALID & AWREADY & WREADY 동시 High
  //            → AXI-Lite 쓰기 핸드쉐이크 완료 시점에서 데이터 캡처.
  // 출력: ap.write(a_item) → scoreboard, coverage에 브로드캐스트.
  //============================================================================
  class axi_wr_monitor extends uvm_monitor;
    `uvm_component_utils(axi_wr_monitor)

    virtual dut_if             _if;
    uvm_analysis_port#(axi_item) ap;
    axi_item                   a_item;

    function new(string name = "axi_wr_monitor", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual dut_if)::get(this, "", "dut_if", _if))
        `uvm_fatal("fatal", "config_db: dut_if get failed")
      ap = new("ap", this);
    endfunction

    virtual task run_phase(uvm_phase phase);
      forever begin
        a_item = new();
        @(posedge _if.ACLK);
        // AXI-Lite 쓰기 핸드쉐이크 완료: AW+W 채널 양방향 Valid/Ready 동시 High
        if(_if.AWVALID && _if.WVALID && _if.AWREADY && _if.WREADY)begin
          `uvm_info("write", $sformatf("REG[%0d] AWADDR:%0d WDATA:%h WSTRB:%b",
            _if.AWADDR[3:2], _if.AWADDR, _if.WDATA, _if.WSTRB), UVM_LOW);
          a_item.awaddr = _if.AWADDR;
          a_item.wdata  = _if.WDATA;
          a_item.wstrb  = _if.WSTRB;
          ap.write(a_item); // scoreboard, coverage로 브로드캐스트
        end
      end
    endtask

  endclass


  //============================================================================
  // 클래스 : axi_rd_monitor (uvm_monitor)
  // 기  능 : AXI-Lite 읽기 트랜잭션을 패시브하게 관측하여 analysis port로 전달.
  //
  // 관측 조건: RVALID & RREADY 동시 High
  //            → R 채널 핸드쉐이크 완료 시점에서 데이터 캡처.
  // 출력: ap.write(a_item) → scoreboard, coverage에 브로드캐스트.
  //============================================================================
  class axi_rd_monitor extends uvm_monitor;
    `uvm_component_utils(axi_rd_monitor)

    virtual dut_if             _if;
    uvm_analysis_port#(axi_item) ap;
    axi_item                   a_item;

    function new(string name = "axi_rd_monitor", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      if(!uvm_config_db#(virtual dut_if)::get(this, "", "dut_if", _if))
        `uvm_fatal("fatal", "config_db: dut_if get failed")
      ap = new("ap", this);
    endfunction

    virtual task run_phase(uvm_phase phase);
      forever begin
        a_item = new();
        @(posedge _if.ACLK);
        // R 채널 핸드쉐이크 완료 시점에서 읽기 데이터 캡처
        if(_if.RVALID && _if.RREADY)begin
          `uvm_info("read", $sformatf("REG[%0d] ARADDR:%0d RDATA:%h",
            _if.ARADDR[3:2], _if.ARADDR, _if.RDATA), UVM_LOW);
          a_item.araddr = _if.ARADDR;
          a_item.rdata  = _if.RDATA;
          ap.write(a_item);
        end
      end
    endtask

  endclass


  // 시퀀서: uvm_sequencer를 typedef로 정의 (별도 커스텀 로직 없음)
  typedef uvm_sequencer#(axi_item) axi_wr_sequencer;
  typedef uvm_sequencer#(axi_item) axi_rd_sequencer;
  typedef uvm_sequencer#(axi_item) axi_all_test_sequencer;


  //============================================================================
  // 클래스 : axi_agent (uvm_agent)
  // 기  능 : wr/rd 드라이버, 모니터, 시퀀서를 하나로 묶는 에이전트.
  //          외부(env)에는 wr_ap, rd_ap만 노출하여 scoreboard/coverage와 연결.
  //============================================================================
  class axi_agent extends uvm_agent;
    `uvm_component_utils(axi_agent)

    axi_wr_driver    a_wr_dri;
    axi_rd_driver    a_rd_dri;
    axi_wr_monitor   wr_mon;
    axi_rd_monitor   rd_mon;
    axi_wr_sequencer wr_seqr;
    axi_rd_sequencer rd_seqr;

    uvm_analysis_port#(axi_item) wr_ap; // env → scoreboard/coverage 쓰기 채널
    uvm_analysis_port#(axi_item) rd_ap; // env → scoreboard/coverage 읽기 채널

    function new(string name = "axi_agent", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      a_wr_dri = axi_wr_driver::type_id::create("a_wr_dri", this);
      a_rd_dri = axi_rd_driver::type_id::create("a_rd_dri", this);
      wr_mon   = axi_wr_monitor::type_id::create("wr_mon",  this);
      rd_mon   = axi_rd_monitor::type_id::create("rd_mon",  this);
      wr_seqr  = axi_wr_sequencer::type_id::create("wr_seqr", this);
      rd_seqr  = axi_rd_sequencer::type_id::create("rd_seqr", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
      a_wr_dri.seq_item_port.connect(wr_seqr.seq_item_export);
      a_rd_dri.seq_item_port.connect(rd_seqr.seq_item_export);
      // 모니터의 ap를 에이전트 레벨로 끌어올림 (env에서 한 번에 연결)
      wr_ap = wr_mon.ap;
      rd_ap = rd_mon.ap;
    endfunction

  endclass


  //============================================================================
  // 매크로: `uvm_analysis_imp_decl(_wr), `uvm_analysis_imp_decl(_rd)
  // 기  능 : 하나의 컴포넌트(scoreboard, coverage)가 wr/rd 두 개의 analysis
  //          imp 포트를 가질 수 있도록 접미사를 붙인 write_wr(), write_rd()
  //          함수를 자동 생성한다.
  //          (동일 클래스에서 write() 함수가 충돌하지 않도록 분리)
  //============================================================================
  `uvm_analysis_imp_decl(_wr)
  `uvm_analysis_imp_decl(_rd)


  //============================================================================
  // 클래스 : axi_scoreboard (uvm_scoreboard)
  // 기  능 : Shadow register로 DUT 내부 상태를 소프트웨어로 추적하고,
  //          읽기 결과(RDATA)와 비교하여 데이터 무결성을 검증한다.
  //
  // Shadow register 규칙:
  //   - write_wr(): WSTRB에 따라 바이트 단위로 shadow 업데이트
  //                 단, REG1(addr[3:2]=01)은 Read-Only이므로 shadow 업데이트 제외
  //   - write_rd(): shadow[araddr[3:2]] vs RDATA 비교
  //                 불일치 시 error 카운터 증가 + uvm_error 출력
  //
  // DUT 레지스터 맵 (AXI_LITE_slave 기준):
  //   0x00 (addr[3:2]=00): CTRL    [RW]
  //   0x04 (addr[3:2]=01): STATUS  [RO] ← shadow 쓰기 제외
  //   0x08 (addr[3:2]=10): CONFIG0 [RW]
  //   0x0C (addr[3:2]=11): CONFIG1 [RW]
  //============================================================================
  class axi_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(axi_scoreboard)

    uvm_analysis_imp_wr#(axi_item, axi_scoreboard) wr_imp;
    uvm_analysis_imp_rd#(axi_item, axi_scoreboard) rd_imp;

    int error;

    function new(string name = "axi_scoreboard", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      wr_imp = new("wr_imp", this);
      rd_imp = new("rd_imp", this);
      error  = 0;
    endfunction

    bit [31:0] shadow[4]; // DUT 레지스터 4개의 소프트웨어 복제본

    // 쓰기 트랜잭션 수신: WSTRB 바이트 마스크에 따라 shadow 업데이트
    function void write_wr(axi_item item);
      if(item.awaddr[3:2] != 2'b01) begin  // STATUS(RO) 레지스터는 shadow 업데이트 제외
        for(int i=0; i<4; i=i+1) begin
          if(item.wstrb[i])
            shadow[item.awaddr[3:2]][i*8 +: 8] = item.wdata[i*8 +: 8];
        end
      end
    endfunction

    // 읽기 트랜잭션 수신: shadow와 RDATA 비교
    function void write_rd(axi_item item);
      if(shadow[item.araddr[3:2]] != item.rdata) begin
        error++;
        `uvm_error("scbd", $sformatf("REG[%0d] shadow:%h rdata:%h",
          item.araddr[3:2], shadow[item.araddr[3:2]], item.rdata))
      end
    endfunction

    virtual function void report_phase(uvm_phase phase);
      if(error == 0)
        `uvm_info("report", "*** PASSED ***", UVM_LOW)
      else
        `uvm_error("report", $sformatf("*** FAILED : %0d error(s) ***", error))
    endfunction

  endclass


  //============================================================================
  // 클래스 : axi_coverage (uvm_component)
  // 기  능 : 쓰기/읽기 트랜잭션을 수신하여 기능 커버리지를 수집한다.
  //
  // 커버그룹:
  //   cg_axi_wr:
  //     cp_wr_addr   : 4개 레지스터 주소(addr[3:2] = 0~3)가 모두 쓰였는지
  //     cp_wstrb     : WSTRB 0000(쓰기 없음), 1111(전체 쓰기), 기타 조합
  //     cs_addr_wstrb: cp_wr_addr × cp_wstrb 크로스 커버리지
  //                    → 각 레지스터에 대해 전체/부분/무쓰기가 모두 발생했는지
  //   cg_axi_rd:
  //     cp_rd_addr   : 4개 레지스터 주소가 모두 읽혔는지
  //
  // 주의: `uvm_analysis_imp_decl은 패키지 전역에서 1회만 선언 가능.
  //       scoreboard와 coverage가 동일 접미사 매크로를 공유.
  //============================================================================
  class axi_coverage extends uvm_component;
    `uvm_component_utils(axi_coverage)

    uvm_analysis_imp_wr#(axi_item, axi_coverage) wr_imp;
    uvm_analysis_imp_rd#(axi_item, axi_coverage) rd_imp;

    axi_item item;

    covergroup cg_axi_wr;
      // 쓰기 주소 커버리지: 4개 레지스터 주소 전부 방문
      cp_wr_addr : coverpoint item.awaddr[3:2] {
        bins reg0[] = {[0:$]};
      }
      // WSTRB 커버리지: all_zero / all_one / 부분 쓰기
      cp_wstrb : coverpoint item.wstrb {
        bins all_zero = {4'b0000};
        bins all_one  = {4'b1111};
        bins others   = default;
      }
      // 크로스 커버리지: 주소×WSTRB 조합
      cs_addr_wstrb : cross cp_wr_addr, cp_wstrb;
    endgroup

    covergroup cg_axi_rd;
      // 읽기 주소 커버리지: 4개 레지스터 주소 전부 방문
      cp_rd_addr : coverpoint item.araddr[3:2] {
        bins reg1[] = {[0:$]};
      }
    endgroup

    function new(string name = "axi_coverage", uvm_component parent = null);
      super.new(name, parent);
      cg_axi_wr = new();
      cg_axi_rd = new();
    endfunction

    virtual function void build_phase(uvm_phase phase);
      wr_imp = new("wr_imp", this);
      rd_imp = new("rd_imp", this);
    endfunction

    virtual function void write_wr(axi_item t);
      item = t;
      cg_axi_wr.sample(); // item 캡처 시점에 커버리지 샘플링
    endfunction

    virtual function void write_rd(axi_item t);
      item = t;
      cg_axi_rd.sample();
    endfunction

    virtual function void report_phase(uvm_phase phase);
      `uvm_info("coverage", $sformatf("cp_wr_addr    = %.2f%%", cg_axi_wr.cp_wr_addr.get_inst_coverage()),    UVM_LOW)
      `uvm_info("coverage", $sformatf("cp_rd_addr    = %.2f%%", cg_axi_rd.cp_rd_addr.get_inst_coverage()),    UVM_LOW)
      `uvm_info("coverage", $sformatf("cp_wstrb      = %.2f%%", cg_axi_wr.cp_wstrb.get_inst_coverage()),      UVM_LOW)
      `uvm_info("coverage", $sformatf("cs_addr_wstrb = %.2f%%", cg_axi_wr.cs_addr_wstrb.get_inst_coverage()), UVM_LOW)
      `uvm_info("coverage", $sformatf("wr 전체 Coverage = %.2f%%", cg_axi_wr.get_inst_coverage()),            UVM_LOW)
      `uvm_info("coverage", $sformatf("rd 전체 Coverage = %.2f%%", cg_axi_rd.get_inst_coverage()),            UVM_LOW)
    endfunction

  endclass


  //============================================================================
  // 클래스 : axi_env (uvm_env)
  // 기  능 : 에이전트, 스코어보드, 커버리지를 하나의 환경으로 통합.
  //          connect_phase에서 모니터 → scoreboard/coverage 분기 연결.
  //============================================================================
  class axi_env extends uvm_env;
    `uvm_component_utils(axi_env)

    axi_agent      axi_ag;
    axi_scoreboard axi_scbd;
    axi_coverage   axi_cg;

    function new(string name = "axi_env", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      axi_ag   =      axi_agent::type_id::create("axi_ag",   this);
      axi_scbd = axi_scoreboard::type_id::create("axi_scbd", this);
      axi_cg   =   axi_coverage::type_id::create("axi_cg",   this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
      // 모니터 ap → scoreboard imp 연결
      axi_ag.wr_ap.connect(axi_scbd.wr_imp);
      axi_ag.rd_ap.connect(axi_scbd.rd_imp);
      // 모니터 ap → coverage imp 연결 (동일 ap에서 분기)
      axi_ag.wr_ap.connect(axi_cg.wr_imp);
      axi_ag.rd_ap.connect(axi_cg.rd_imp);
    endfunction

  endclass


  //============================================================================
  // 클래스 : axi_wr_sequence (uvm_sequence)
  // 기  능 : num_tx회 랜덤 쓰기 트랜잭션을 생성하는 시퀀스.
  //          randomize()로 awaddr, wdata, wstrb를 랜덤 생성 후 드라이버에 전달.
  //          get_response()로 드라이버 완료 시점을 수신 (순서 보장).
  //============================================================================
  class axi_wr_sequence extends uvm_sequence#(axi_item);
    `uvm_object_utils(axi_wr_sequence)

    axi_item item;
    int num_tx = 10;

    function new(string name = "axi_wr_sequence");
      super.new(name);
    endfunction

    virtual task body();
      repeat(num_tx) begin
        item = axi_item::type_id::create("item");
        start_item(item);
        assert(item.randomize());
        finish_item(item);
        get_response(item); // 드라이버 item_done() 이후 언블록
      end
    endtask

  endclass


  //============================================================================
  // 클래스 : axi_rd_sequence (uvm_sequence)
  // 기  능 : num_tx회 읽기 트랜잭션을 생성하는 시퀀스.
  //          araddr은 랜덤 생성되지만, rd_driver 내부에서 addr_q의 주소로 덮어씀.
  //          (실제 읽기 주소는 wr_driver가 기록한 주소를 따름)
  //============================================================================
  class axi_rd_sequence extends uvm_sequence#(axi_item);
    `uvm_object_utils(axi_rd_sequence)

    axi_item item;
    int num_tx = 10;

    function new(string name = "axi_rd_sequence");
      super.new(name);
    endfunction

    virtual task body();
      repeat(num_tx) begin
        item = axi_item::type_id::create("item");
        start_item(item);
        assert(item.randomize());
        finish_item(item);
        get_response(item);
      end
    endtask

  endclass


  //============================================================================
  // 클래스 : axi_all_test_sequence (uvm_sequence)
  // 기  능 : 커버리지 100% 달성을 위한 결정적(deterministic) 시퀀스.
  //
  // 동작:
  //   1단계: 4개 레지스터 × wstrb=0000 (쓰기 없음 → 데이터 변화 없음 확인)
  //   2단계: 4개 레지스터 × wstrb=1111 (전체 쓰기 → 랜덤 데이터 기록)
  //
  //   → cp_wstrb의 all_zero, all_one 빈 + 모든 주소 조합을 보장하여
  //     cs_addr_wstrb 크로스 커버리지를 빠르게 달성.
  //
  // awaddr 계산: i << 2 → 0x00, 0x04, 0x08, 0x0C (레지스터 오프셋)
  //============================================================================
  class axi_all_test_sequence extends uvm_sequence#(axi_item);
    `uvm_object_utils(axi_all_test_sequence)

    axi_item item;

    function new(string name = "at_seq");
      super.new(name);
    endfunction

    virtual task body();
      // 1단계: 모든 레지스터에 wstrb=0000 (no-op write)
      for(int i=0; i<4; i=i+1) begin
        item = axi_item::type_id::create("item");
        start_item(item);
        item.awaddr = i << 2;  // 0x00, 0x04, 0x08, 0x0C
        item.wstrb  = 4'b0000;
        item.wdata  = $urandom();
        finish_item(item);
        get_response(item);
      end
      // 2단계: 모든 레지스터에 wstrb=1111 (full write)
      for(int i=0; i<4; i=i+1) begin
        item = axi_item::type_id::create("item");
        start_item(item);
        item.awaddr = i << 2;
        item.wstrb  = 4'b1111;
        item.wdata  = $urandom();
        finish_item(item);
        get_response(item);
      end
    endtask

  endclass


  //============================================================================
  // 클래스 : axi_test (uvm_test)
  // 기  능 : 최상위 테스트. 환경 생성 및 시퀀스 실행을 총괄.
  //
  // 실행 순서:
  //   1. all_test_seq: 커버리지 목표 달성을 위한 결정적 시나리오 먼저 실행
  //   2. repeat(50): 랜덤 쓰기 1회 + 랜덤 읽기 1회를 50세트 반복
  //                  → 랜덤 자극으로 예상치 못한 코너 케이스 탐색
  //
  // addr_q 공유:
  //   build_phase에서 생성 후 config_db로 등록 → wr/rd driver가 get()으로 수신.
  //   "*"로 계층 전체에 전파하여 드라이버가 어느 위치에 있어도 수신 가능.
  //============================================================================
  class axi_test extends uvm_test;
    `uvm_component_utils(axi_test)

    axi_env               a_env;
    axi_wr_sequence       a_wr_seq;
    axi_rd_sequence       a_rd_seq;
    axi_all_test_sequence all_test_seq;
    addr_queue_obj        addr_q;

    function new(string name = "axi_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
      a_env  =        axi_env::type_id::create("a_env",  this);
      addr_q = addr_queue_obj::type_id::create("addr_q");
      // wr/rd driver가 공통으로 참조할 주소 큐를 config_db로 공유
      uvm_config_db#(addr_queue_obj)::set(this, "*", "addr_q", addr_q);
    endfunction

    virtual task run_phase(uvm_phase phase);
      phase.raise_objection(this);

      a_wr_seq     =       axi_wr_sequence::type_id::create("a_wr_seq");
      a_rd_seq     =       axi_rd_sequence::type_id::create("a_rd_seq");
      all_test_seq = axi_all_test_sequence::type_id::create("all_test_seq");

      // 결정적 시나리오: 커버리지 목표 우선 달성
      all_test_seq.start(a_env.axi_ag.wr_seqr);

      // 랜덤 시나리오: 쓰기 1회 + 읽기 1회 × 50회 반복
      a_wr_seq.num_tx = 1;
      a_rd_seq.num_tx = 1;
      repeat(50) begin
        a_wr_seq.start(a_env.axi_ag.wr_seqr);
        a_rd_seq.start(a_env.axi_ag.rd_seqr);
      end

      phase.drop_objection(this);
    endtask

  endclass

endpackage


//==============================================================================
// 모듈 : tb_top
// 기 능: UVM 테스트를 시작하는 최상위 테스트벤치 모듈.
//
// 구성:
//   - dut_if 인스턴스를 생성하고 DUT(my_AXI_LITE_slave)에 신호 연결
//   - uvm_config_db로 dut_if를 전체 UVM 계층에 등록
//   - run_test("axi_test")로 UVM 실행 시작
//
// 리셋 시퀀스:
//   ARESETn = 0으로 시작 → 5클럭 후 ARESETn = 1 (DUT 리셋 해제)
//==============================================================================
module tb_top();
  import uvm_pkg::*;
  import axi_lite_slave::*;

  localparam ADDR_WIDTH = 4;
  localparam DATA_WIDTH = 32;

  logic ACLK;
  logic ARESETn;

  dut_if _if(ACLK);

  my_AXI_LITE_slave #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
  ) axi_slave0 (
    .ACLK(ACLK),         .ARESETn(ARESETn),
    .AWVALID(_if.AWVALID), .AWREADY(_if.AWREADY), .AWADDR(_if.AWADDR),
    .WVALID(_if.WVALID),   .WREADY(_if.WREADY),
    .WDATA(_if.WDATA),     .WSTRB(_if.WSTRB),
    .BVALID(_if.BVALID),   .BREADY(_if.BREADY),
    .ARVALID(_if.ARVALID), .ARREADY(_if.ARREADY), .ARADDR(_if.ARADDR),
    .RVALID(_if.RVALID),   .RREADY(_if.RREADY),   .RDATA(_if.RDATA)
  );

  always #5 ACLK = ~ACLK;

  initial begin
    ACLK    <= 0;
    ARESETn <= 0;
    repeat(5) @(posedge _if.ACLK);
    ARESETn <= 1;  // 리셋 해제
  end

  initial begin
    // dut_if를 UVM 전체 계층에 등록 (드라이버/모니터가 config_db로 수신)
    uvm_config_db#(virtual dut_if)::set(null, "uvm_test_top.*", "dut_if", _if);
    run_test("axi_test");
  end

endmodule
