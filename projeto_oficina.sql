-- projeto_oficina.sql
-- Projeto: Sistema para Oficina Mecânica (PostgreSQL)
-- Script completo: criação do esquema, constraints, triggers e dados de exemplo.

BEGIN;

-- 1) CONTAS (Clientes: PF/PJ)
CREATE TABLE accounts (
    account_id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE,
    password_hash VARCHAR(255),
    display_name VARCHAR(200),
    account_type CHAR(2) NOT NULL CHECK (account_type IN ('PF','PJ')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE client_pf (
    account_id INT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
    cpf CHAR(11) NOT NULL UNIQUE,
    full_name VARCHAR(200) NOT NULL,
    birth_date DATE,
    CHECK ((SELECT account_type FROM accounts WHERE account_id = client_pf.account_id) = 'PF')
);

CREATE TABLE client_pj (
    account_id INT PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
    cnpj CHAR(14) NOT NULL UNIQUE,
    company_name VARCHAR(255) NOT NULL,
    trade_name VARCHAR(255),
    CHECK ((SELECT account_type FROM accounts WHERE account_id = client_pj.account_id) = 'PJ')
);

-- 2) VEÍCULOS
CREATE TABLE vehicles (
    vehicle_id SERIAL PRIMARY KEY,
    account_id INT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    plate VARCHAR(10) NOT NULL UNIQUE,
    vin VARCHAR(50) UNIQUE,
    make VARCHAR(100),
    model VARCHAR(100),
    year INT CHECK (year > 1885 AND year <= EXTRACT(YEAR FROM now())::int + 1),
    color VARCHAR(50),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 3) EMPREGADOS
CREATE TABLE employees (
    employee_id SERIAL PRIMARY KEY,
    full_name VARCHAR(200) NOT NULL,
    role VARCHAR(50) NOT NULL,
    hire_date DATE,
    active BOOLEAN DEFAULT TRUE,
    hourly_rate NUMERIC(10,2) CHECK (hourly_rate >= 0)
);

-- 4) FORNECEDORES
CREATE TABLE suppliers (
    supplier_id SERIAL PRIMARY KEY,
    supplier_name VARCHAR(255) NOT NULL,
    contact_email VARCHAR(255),
    phone VARCHAR(30)
);

-- 5) PEÇAS E ESTOQUE
CREATE TABLE parts (
    part_id SERIAL PRIMARY KEY,
    sku VARCHAR(80) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    unit_cost NUMERIC(12,2) NOT NULL CHECK (unit_cost >= 0),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE part_stock (
    part_id INT PRIMARY KEY REFERENCES parts(part_id) ON DELETE CASCADE,
    total_qty INT DEFAULT 0 CHECK (total_qty >= 0),
    last_updated TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE part_suppliers (
    part_id INT NOT NULL REFERENCES parts(part_id) ON DELETE CASCADE,
    supplier_id INT NOT NULL REFERENCES suppliers(supplier_id) ON DELETE CASCADE,
    supplier_sku VARCHAR(100),
    supplier_price NUMERIC(12,2) CHECK (supplier_price >= 0),
    available_qty INT DEFAULT 0 CHECK (available_qty >= 0),
    PRIMARY KEY (part_id, supplier_id)
);

-- 6) ORDENS DE SERVIÇO
CREATE TABLE service_orders (
    os_id SERIAL PRIMARY KEY,
    account_id INT NOT NULL REFERENCES accounts(account_id) ON DELETE RESTRICT,
    vehicle_id INT REFERENCES vehicles(vehicle_id) ON DELETE SET NULL,
    opened_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    closed_at TIMESTAMP WITH TIME ZONE,
    status VARCHAR(30) NOT NULL DEFAULT 'open',
    assigned_employee_id INT REFERENCES employees(employee_id),
    notes TEXT
);

-- 7) SERVIÇOS (catalog)
CREATE TABLE services (
    service_id SERIAL PRIMARY KEY,
    code VARCHAR(50) UNIQUE NOT NULL,
    description VARCHAR(255) NOT NULL,
    labor_hours NUMERIC(5,2) DEFAULT 1 CHECK (labor_hours >= 0),
    hourly_rate NUMERIC(10,2) DEFAULT 0 CHECK (hourly_rate >= 0)
);

-- 8) ITENS DE ORDEM
CREATE TABLE os_services (
    os_service_id SERIAL PRIMARY KEY,
    os_id INT NOT NULL REFERENCES service_orders(os_id) ON DELETE CASCADE,
    service_id INT NOT NULL REFERENCES services(service_id),
    performed_by INT REFERENCES employees(employee_id),
    hours_worked NUMERIC(5,2) NOT NULL CHECK (hours_worked >= 0),
    unit_price NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0)
);

CREATE TABLE os_parts (
    os_part_id SERIAL PRIMARY KEY,
    os_id INT NOT NULL REFERENCES service_orders(os_id) ON DELETE CASCADE,
    part_id INT NOT NULL REFERENCES parts(part_id),
    supplier_id INT REFERENCES suppliers(supplier_id),
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_cost NUMERIC(12,2) NOT NULL CHECK (unit_cost >= 0)
);

-- 9) PAGAMENTOS
CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    os_id INT NOT NULL REFERENCES service_orders(os_id) ON DELETE CASCADE,
    payment_date TIMESTAMP WITH TIME ZONE DEFAULT now(),
    method VARCHAR(50) NOT NULL,
    amount NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    note VARCHAR(255)
);

-- 10) ÍNDICES
CREATE INDEX idx_vehicles_account ON vehicles(account_id);
CREATE INDEX idx_os_account ON service_orders(account_id);
CREATE INDEX idx_os_status ON service_orders(status);

-- 11) TRIGGERS / FUNÇÕES
CREATE OR REPLACE FUNCTION refresh_part_stock() RETURNS trigger AS $$
BEGIN
    UPDATE part_stock
    SET total_qty = (SELECT COALESCE(SUM(available_qty),0) FROM part_suppliers WHERE part_id = NEW.part_id),
        last_updated = now()
    WHERE part_id = NEW.part_id;
    IF NOT FOUND THEN
        INSERT INTO part_stock(part_id, total_qty, last_updated)
        VALUES (NEW.part_id, (SELECT COALESCE(SUM(available_qty),0) FROM part_suppliers WHERE part_id = NEW.part_id), now())
        ON CONFLICT (part_id) DO UPDATE SET total_qty = EXCLUDED.total_qty, last_updated = EXCLUDED.last_updated;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_refresh_part_stock
AFTER INSERT OR UPDATE OR DELETE ON part_suppliers
FOR EACH ROW EXECUTE FUNCTION refresh_part_stock();

CREATE OR REPLACE FUNCTION consume_supplier_stock() RETURNS trigger AS $$
DECLARE
    cur_qty INT;
BEGIN
    IF NEW.supplier_id IS NOT NULL THEN
        SELECT available_qty INTO cur_qty FROM part_suppliers WHERE part_id = NEW.part_id AND supplier_id = NEW.supplier_id FOR UPDATE;
        IF FOUND THEN
            IF cur_qty < NEW.quantity THEN
                RAISE EXCEPTION 'Estoque insuficiente no fornecedor % para a peça %', NEW.supplier_id, NEW.part_id;
            END IF;
            UPDATE part_suppliers
            SET available_qty = available_qty - NEW.quantity
            WHERE part_id = NEW.part_id AND supplier_id = NEW.supplier_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_consume_supplier_stock
AFTER INSERT ON os_parts
FOR EACH ROW EXECUTE FUNCTION consume_supplier_stock();

CREATE OR REPLACE FUNCTION calc_os_total(p_os_id INT) RETURNS NUMERIC AS $$
DECLARE
    v_total NUMERIC := 0;
BEGIN
    SELECT COALESCE(SUM(os.hours_worked * os.unit_price),0) INTO v_total FROM os_services os WHERE os.os_id = p_os_id;
    v_total := v_total + COALESCE((SELECT SUM(op.quantity * op.unit_cost) FROM os_parts op WHERE op.os_id = p_os_id),0);
    RETURN v_total;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION check_close_os() RETURNS trigger AS $$
DECLARE
    total_pagamentos NUMERIC;
    total_os NUMERIC;
BEGIN
    SELECT COALESCE(SUM(amount),0) INTO total_pagamentos FROM payments WHERE os_id = NEW.os_id;
    total_os := calc_os_total(NEW.os_id);
    IF total_os > 0 AND total_pagamentos >= total_os THEN
        UPDATE service_orders SET status = 'closed', closed_at = now() WHERE os_id = NEW.os_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_close_os
AFTER INSERT OR UPDATE ON payments
FOR EACH ROW EXECUTE FUNCTION check_close_os();

-- 12) DADOS DE EXEMPLO
INSERT INTO accounts (email,password_hash,display_name,account_type) VALUES
('carlos@example.com','$h1','Carlos Auto','PF'),
('empresaauto@example.com','$h2','Empresa Auto LTDA','PJ'),
('ana@example.com','$h3','Ana Silva','PF');

INSERT INTO client_pf (account_id,cpf,full_name,birth_date) VALUES
(1,'11122233344','Carlos da Silva','1980-05-12'),
(3,'55566677788','Ana Maria Silva','1990-09-01');

INSERT INTO client_pj (account_id,cnpj,company_name,trade_name) VALUES
(2,'12345678000199','Empresa Auto LTDA','EmpAuto');

INSERT INTO vehicles (account_id,plate,vin,make,model,year,color) VALUES
(1,'ABC1D23','VIN000111','Ford','Ka',2015,'Branco'),
(1,'XYZ9Z88','VIN000222','Volkswagen','Gol',2012,'Prata'),
(3,'QWE2R34','VIN000333','Chevrolet','Onix',2018,'Preto');

INSERT INTO employees (full_name,role,hire_date,active,hourly_rate) VALUES
('José Mecânico','mechanic','2018-03-01',TRUE,45.00),
('Luana Atendente','attendant','2020-06-15',TRUE,25.00),
('Rafael Chefe','manager','2015-01-10',TRUE,70.00);

INSERT INTO suppliers (supplier_name,contact_email,phone) VALUES
('Peças Gerais','pecas@fornecedor.com','+55-11-95555-0001'),
('Fornecedor Alfa','contato@alfa.com','+55-21-98888-0002');

INSERT INTO parts (sku,name,description,unit_cost) VALUES
('PART-001','Filtro de Óleo','Filtro de óleo para motores 1.0/1.4',15.50),
('PART-002','Pastilha de Freio','Pastilha dianteira',75.00),
('PART-003','Velas','Conjunto de 4 velas',40.00);

INSERT INTO part_suppliers (part_id,supplier_id,supplier_sku,supplier_price,available_qty) VALUES
(1,1,'PG-FILT-01',12.00,100),
(2,1,'PG-FREIO-02',60.00,20),
(3,2,'AL-VELA-03',30.00,5);

INSERT INTO service_orders (account_id,vehicle_id,opened_at,status,assigned_employee_id,notes) VALUES
(1,1,now()-interval '5 days','in_progress',1,'Troca de óleo e inspeção geral'),
(1,2,now()-interval '2 days','awaiting_parts',1,'Troca de pastilhas dianteiras'),
(3,3,now()-interval '1 days','open',2,'Diagnóstico de ruído');

INSERT INTO services (code,description,labor_hours,hourly_rate) VALUES
('SVC-OIL','Troca de óleo',1.0,60.00),
('SVC-BRAKE','Substituição pastilhas',2.0,80.00),
('SVC-DIAG','Diagnóstico',1.5,50.00);

INSERT INTO os_services (os_id,service_id,performed_by,hours_worked,unit_price) VALUES
(1,1,1,1.0,60.00),
(2,2,1,2.0,80.00),
(3,3,2,1.5,50.00);

INSERT INTO os_parts (os_id,part_id,supplier_id,quantity,unit_cost) VALUES
(1,1,1,1,12.00),
(2,2,1,2,60.00);

INSERT INTO payments (os_id,payment_date,method,amount,note) VALUES
(1, now()-interval '1 days', 'card', 72.00, 'Pagamento parcial'),
(2, now(), 'pix', 120.00, 'Pagamento adiantado');


