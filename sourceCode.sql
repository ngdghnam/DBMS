USE WideWorldImporters;
go

-- Bước 1: Tạo bảng lưu danh sách Partition Points động
CREATE TABLE #PartitionValues (PartitionValue DATE);
GO

DECLARE @MinDate DATE, @MaxDate DATE;
SELECT @MinDate = MIN(LastEditedWhen), @MaxDate = MAX(LastEditedWhen) FROM Sales.InvoiceLines;
DECLARE @CurrentDate DATE = @MinDate;
WHILE @CurrentDate <= @MaxDate
BEGIN
    INSERT INTO #PartitionValues VALUES (@CurrentDate);
    SET @CurrentDate = DATEADD(MONTH, 1, @CurrentDate);
END;
GO

-- Bước 2: Tạo Partition Function động
DECLARE @SQL NVARCHAR(MAX) = 'CREATE PARTITION FUNCTION DynamicPartFunc (DATE) AS RANGE LEFT FOR VALUES (';
SELECT @SQL = @SQL + STRING_AGG('''' + CONVERT(NVARCHAR, PartitionValue, 23) + '''', ', ') FROM #PartitionValues;
SET @SQL = @SQL + ')';
PRINT @SQL;
EXEC(@SQL);

-- Bước 3: Tạo Partition Scheme
EXEC('CREATE PARTITION SCHEME DynamicPartScheme AS PARTITION DynamicPartFunc ALL TO ([PRIMARY])');

-- Bước 4: Tạo bảng Partitioned với mã hóa AES-256
CREATE TABLE dbo.New_InvoiceLines5 (
    InvoiceLineID VARBINARY(MAX) NOT NULL,
    LineProfit VARBINARY(MAX) NOT NULL,
    ExtendedPrice VARBINARY(MAX) NOT NULL,
    StockItemID VARBINARY(MAX) NOT NULL,
    Quantity VARBINARY(MAX) NOT NULL,
    LastEditedWhen DATE NOT NULL
) ON DynamicPartScheme(LastEditedWhen);

-- Bước 5: Chuyển dữ liệu vào bảng Partitioned với mã hóa
OPEN SYMMETRIC KEY MySymmetricKey DECRYPTION BY CERTIFICATE MyCertificate;

INSERT INTO dbo.New_InvoiceLines5
SELECT 
    EncryptByKey(Key_GUID('MySymmetricKey'), CAST(InvoiceLineID AS VARBINARY(MAX))),
    EncryptByKey(Key_GUID('MySymmetricKey'), CAST(LineProfit AS VARBINARY(MAX))),
    EncryptByKey(Key_GUID('MySymmetricKey'), CAST(ExtendedPrice AS VARBINARY(MAX))),
    EncryptByKey(Key_GUID('MySymmetricKey'), CAST(StockItemID AS VARBINARY(MAX))),
    EncryptByKey(Key_GUID('MySymmetricKey'), CAST(Quantity AS VARBINARY(MAX))),
    LastEditedWhen -- ❌ Không mã hóa cột này
FROM Sales.InvoiceLines;

CLOSE SYMMETRIC KEY MySymmetricKey;

SELECT * FROM New_InvoiceLines5


-- Bước 6: Tạo bảng không Partitioned với mã hóa
CREATE TABLE dbo.New_InvoiceLines_NoPartition6 (
    InvoiceLineID VARBINARY(MAX) NOT NULL,
    LineProfit VARBINARY(MAX) NOT NULL,
    ExtendedPrice VARBINARY(MAX) NOT NULL,
    StockItemID VARBINARY(MAX) NOT NULL,
    Quantity VARBINARY(MAX) NOT NULL,
    LastEditedWhen DATE NOT NULL
);

OPEN SYMMETRIC KEY MySymmetricKey DECRYPTION BY CERTIFICATE MyCertificate;

INSERT INTO dbo.New_InvoiceLines_NoPartition6
SELECT 
    EncryptByKey(Key_GUID('MySymmetricKey'), CAST(InvoiceLineID AS VARBINARY(MAX))),
    EncryptByKey(Key_GUID('MySymmetricKey'), CAST(LineProfit AS VARBINARY(MAX))),
    EncryptByKey(Key_GUID('MySymmetricKey'), CAST(ExtendedPrice AS VARBINARY(MAX))),
    EncryptByKey(Key_GUID('MySymmetricKey'), CAST(StockItemID AS VARBINARY(MAX))),
    EncryptByKey(Key_GUID('MySymmetricKey'), CAST(Quantity AS VARBINARY(MAX))),
    LastEditedWhen
FROM Sales.InvoiceLines;

CLOSE SYMMETRIC KEY MySymmetricKey;


-- Bước 7: Tạo Clustered Columnstore Index (CCI)
CREATE CLUSTERED COLUMNSTORE INDEX CCI_NewInvoiceLines ON dbo.New_InvoiceLines5;

-- Bước 8: Định nghĩa hàm Dynamic Monthly Sales với giải mã
CREATE FUNCTION dbo.GetMonthlySales5 (@Year INT, @Month INT)
RETURNS TABLE
AS
RETURN
(
    SELECT 
        SUM(CAST(DecryptByKey(CAST(ExtendedPrice AS VARBINARY(MAX))) AS DECIMAL(18,2))) AS MonthlyRevenue, 
        SUM(CAST(DecryptByKey(CAST(LineProfit AS VARBINARY(MAX))) AS DECIMAL(18,2))) AS MonthlyProfit
    FROM dbo.New_InvoiceLines5
    WHERE LastEditedWhen >= DATEFROMPARTS(@Year, @Month, 1)
          AND LastEditedWhen < DATEADD(MONTH, 1, DATEFROMPARTS(@Year, @Month, 1))
);


-- Bước 9: Tạo bảng log thời gian thực thi
CREATE TABLE dbo.ExecutionTimeLog5 (
    QueryName NVARCHAR(100), 
    StartTime DATETIME, 
    EndTime DATETIME, 
    ElapsedTime INT,    
    CPUTime INT,        
    AdditionalInfo NVARCHAR(255),
    CPUPercentage DECIMAL(5,2)
);

-- Bước 10: Ghi nhận thời gian thực thi, bao gồm cả thời gian giải mã
DECLARE @StartTime DATETIME, @EndTime DATETIME;
DECLARE @ElapsedTime BIGINT, @CPUTime BIGINT;
DECLARE @CPUPercentage DECIMAL(5,2);

-- Mở symmetric key
IF NOT EXISTS (SELECT * FROM sys.symmetric_keys WHERE name = 'AESKey')
BEGIN
    CREATE SYMMETRIC KEY AESKey  
    WITH ALGORITHM = AES_256  
    ENCRYPTION BY PASSWORD = 'YourStrongPassword';
END

OPEN SYMMETRIC KEY AESKey DECRYPTION BY PASSWORD = 'YourStrongPassword';

-- Bắt đầu đo thời gian
SET @StartTime = GETDATE();

SET STATISTICS TIME ON;

OPEN SYMMETRIC KEY MySymmetricKey DECRYPTION BY CERTIFICATE MyCertificate;
SELECT * FROM dbo.GetMonthlySales5(2015, 2);
CLOSE SYMMETRIC KEY MySymmetricKey;


SET STATISTICS TIME OFF;

-- Kết thúc đo thời gian
SET @EndTime = GETDATE();
CLOSE SYMMETRIC KEY AESKey;

-- Tính thời gian thực thi
SET @ElapsedTime = DATEDIFF(MILLISECOND, @StartTime, @EndTime);

-- Lấy CPU time
SELECT @CPUTime = CAST(cpu_time AS BIGINT) 
FROM sys.dm_exec_requests 
WHERE session_id = @@SPID;

-- Tính % CPU sử dụng
SET @CPUPercentage = CASE 
    WHEN @ElapsedTime > 0 THEN (CAST(@CPUTime AS DECIMAL(10,2)) / @ElapsedTime) * 100 
    ELSE 0 
END;

-- Ghi log thời gian thực thi vào bảng
INSERT INTO dbo.ExecutionTimeLog5(QueryName, StartTime, EndTime, ElapsedTime, CPUTime, CPUPercentage, AdditionalInfo) 
VALUES ('Partitioned Query with AES-256 Decryption', @StartTime, @EndTime, @ElapsedTime, @CPUTime, @CPUPercentage, 'Includes AES-256 Decryption');


-- Kiểm tra code không p dung kỹ thuật
-- Bước 10: Ghi nhận thời gian thực thi, bao gồm cả thời gian giải mã
DECLARE @StartTime DATETIME, @EndTime DATETIME;
DECLARE @ElapsedTime BIGINT, @CPUTime BIGINT;
DECLARE @CPUPercentage DECIMAL(5,2);

-- Mở symmetric key
IF NOT EXISTS (SELECT * FROM sys.symmetric_keys WHERE name = 'AESKey')
BEGIN
    CREATE SYMMETRIC KEY AESKey  
    WITH ALGORITHM = AES_256  
    ENCRYPTION BY PASSWORD = 'YourStrongPassword';
END

OPEN SYMMETRIC KEY AESKey DECRYPTION BY PASSWORD = 'YourStrongPassword';

-- Bắt đầu đo thời gian
SET @StartTime = GETDATE();

SET STATISTICS TIME ON;

SELECT 
    SUM(CAST(DecryptByKey(CAST(ExtendedPrice AS VARBINARY(MAX))) AS DECIMAL(18,2))) AS MonthlyRevenue, 
    SUM(CAST(DecryptByKey(CAST(LineProfit AS VARBINARY(MAX))) AS DECIMAL(18,2))) AS MonthlyProfit
FROM dbo.New_InvoiceLines_NoPartition6
WHERE LastEditedWhen >= DATEFROMPARTS(2015,2, 1)
        AND LastEditedWhen < DATEADD(MONTH, 1, DATEFROMPARTS(2015,2, 1))


SET STATISTICS TIME OFF;

-- Kết thúc đo thời gian
SET @EndTime = GETDATE();
CLOSE SYMMETRIC KEY AESKey;

-- Tính thời gian thực thi
SET @ElapsedTime = DATEDIFF(MILLISECOND, @StartTime, @EndTime);

-- Lấy CPU time
SELECT @CPUTime = CAST(cpu_time AS BIGINT) 
FROM sys.dm_exec_requests 
WHERE session_id = @@SPID;

-- Tính % CPU sử dụng
SET @CPUPercentage = CASE 
    WHEN @ElapsedTime > 0 THEN (CAST(@CPUTime AS DECIMAL(10,2)) / @ElapsedTime) * 100 
    ELSE 0 
END;

-- Ghi log thời gian thực thi vào bảng
INSERT INTO dbo.ExecutionTimeLog5(QueryName, StartTime, EndTime, ElapsedTime, CPUTime, CPUPercentage, AdditionalInfo) 
VALUES ('Partitioned Query with AES-256 Decryption', @StartTime, @EndTime, @ElapsedTime, @CPUTime, @CPUPercentage, 'Includes AES-256 Decryption');



-- Kiểm tra log
SELECT * FROM dbo.ExecutionTimeLog5;

-- Dọn dẹp bảng tạm
DROP TABLE #PartitionValues;
