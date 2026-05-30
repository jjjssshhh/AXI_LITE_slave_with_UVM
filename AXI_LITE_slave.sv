`timescale 1ns / 1ps





module my_AXI_LITE_slave #(
    parameter ADDR_WIDTH = 4,
    parameter DATA_WIDTH = 32
)(
    // Global
    input  wire                    ACLK,
    input  wire                    ARESETn,

    // Write Address Channel
    input  wire                    AWVALID,
    output reg                     AWREADY,
    input  wire [ADDR_WIDTH-1:0]   AWADDR,
    input  wire [2:0]              AWPROT,

    // Write Data Channel
    input  wire                    WVALID,
    output reg                     WREADY,
    input  wire [DATA_WIDTH-1:0]   WDATA,
    input  wire [DATA_WIDTH/8-1:0] WSTRB,

    // Write Response Channel
    output reg                     BVALID,
    input  wire                    BREADY,
    output reg  [1:0]              BRESP,

    // Read Address Channel
    input  wire                    ARVALID,
    output reg                     ARREADY,
    input  wire [ADDR_WIDTH-1:0]   ARADDR,
    input  wire [2:0]              ARPROT,

    // Read Data Channel
    output reg                     RVALID,
    input  wire                    RREADY,
    output reg  [DATA_WIDTH-1:0]   RDATA,
    output reg  [1:0]              RRESP
);

    // Register Map
    // 0x00: CTRL    [RW]
    // 0x04: STATUS  [RO]
    // 0x08: CONFIG0 [RW]
    // 0x0C: CONFIG1 [RW]

    reg [DATA_WIDTH-1:0] slv_reg0;  // CTRL
    reg [DATA_WIDTH-1:0] slv_reg1;  // STATUS (RO)
    reg [DATA_WIDTH-1:0] slv_reg2;  // CONFIG0
    reg [DATA_WIDTH-1:0] slv_reg3;  // CONFIG1

    reg [ADDR_WIDTH-1:0] aw_addr_lat;  // latched write address
    reg                  aw_en;        // write address accepted flag

    // ----------------------------------------------------------------
    // Write Address Channel
    // ----------------------------------------------------------------
    always @(posedge ACLK) begin
        if (!ARESETn) begin
            AWREADY    <= 1'b0;
            aw_en      <= 1'b1;
            aw_addr_lat <= '0;
        end else begin
            if (!AWREADY && AWVALID && aw_en) begin
                AWREADY     <= 1'b1;
                aw_en       <= 1'b0;
                aw_addr_lat <= AWADDR;
            end else if (BREADY && BVALID) begin
                AWREADY <= 1'b0;
                aw_en   <= 1'b1;
            end else begin
                AWREADY <= 1'b0;
            end
        end
    end

    // ----------------------------------------------------------------
    // Write Data Channel
    // ----------------------------------------------------------------
    always @(posedge ACLK) begin
        if (!ARESETn) begin
            WREADY <= 1'b0;
        end else begin
            if (!WREADY && WVALID && aw_en) begin
                WREADY <= 1'b1;
            end else begin
                WREADY <= 1'b0;
            end
        end
    end

    // ----------------------------------------------------------------
    // Register Write
    // ----------------------------------------------------------------
    integer i;
    always @(posedge ACLK) begin
        if (!ARESETn) begin
            slv_reg0 <= '0;
            slv_reg1 <= '0;
            slv_reg2 <= '0;
            slv_reg3 <= '0;
        end else begin
            if (AWREADY && AWVALID && WREADY && WVALID) begin
                case (aw_addr_lat[3:2])
                    2'b00: begin  // 0x00 CTRL [RW]
                        for (i = 0; i < DATA_WIDTH/8; i = i + 1)
                            if (WSTRB[i]) slv_reg0[i*8 +: 8] <= WDATA[i*8 +: 8];
                    end
                    2'b01: begin  // 0x04 STATUS [RO] - write ignored
                    end
                    2'b10: begin  // 0x08 CONFIG0 [RW]
                        for (i = 0; i < DATA_WIDTH/8; i = i + 1)
                            if (WSTRB[i]) slv_reg2[i*8 +: 8] <= WDATA[i*8 +: 8];
                    end
                    2'b11: begin  // 0x0C CONFIG1 [RW]
                        for (i = 0; i < DATA_WIDTH/8; i = i + 1)
                            if (WSTRB[i]) slv_reg3[i*8 +: 8] <= WDATA[i*8 +: 8];
                    end
                endcase
            end
        end
    end

    // ----------------------------------------------------------------
    // Write Response Channel
    // ----------------------------------------------------------------
    always @(posedge ACLK) begin
        if (!ARESETn) begin
            BVALID <= 1'b0;
            BRESP  <= 2'b00;
        end else begin
            if (AWREADY && AWVALID && WREADY && WVALID && !BVALID) begin
                BVALID <= 1'b1;
                BRESP  <= 2'b00;  // OKAY
            end else if (BREADY && BVALID) begin
                BVALID <= 1'b0;
            end
        end
    end

    // ----------------------------------------------------------------
    // Read Address Channel
    // ----------------------------------------------------------------
    always @(posedge ACLK) begin
        if (!ARESETn) begin
            ARREADY <= 1'b0;
        end else begin
            if (!ARREADY && ARVALID) begin
                ARREADY <= 1'b1;
            end else begin
                ARREADY <= 1'b0;
            end
        end
    end

    // ----------------------------------------------------------------
    // Read Data Channel
    // ----------------------------------------------------------------
    always @(posedge ACLK) begin
        if (!ARESETn) begin
            RVALID <= 1'b0;
            RDATA  <= '0;
            RRESP  <= 2'b00;
        end else begin
            if (ARREADY && ARVALID && !RVALID) begin
                RVALID <= 1'b1;
                RRESP  <= 2'b00;  // OKAY
                case (ARADDR[3:2])
                    2'b00: RDATA <= slv_reg0;
                    2'b01: RDATA <= slv_reg1;
                    2'b10: RDATA <= slv_reg2;
                    2'b11: RDATA <= slv_reg3;
                endcase
            end else if (RVALID && RREADY) begin
                RVALID <= 1'b0;
            end
        end
    end

endmodule
