# Projeto: Sistema de Gerenciamento para Oficina Mecânica

## Visão Geral
Este projeto implementa o **modelo lógico de banco de dados** para o contexto de uma oficina mecânica. Cobre:
- Clientes (PF e PJ) e seus veículos.
- Ordens de Serviço (OS) com serviços e peças consumidas.
- Catálogo de serviços (mão de obra), peças e fornecedores.
- Funcionários (mecânicos, atendentes).
- Controle de estoque por fornecedor e agregado.
- Pagamentos associados a ordens de serviço.

O esquema foi modelado pensando em integridade referencial, controles de estoque e automatizações via triggers.

---

## Como usar
1. Instale PostgreSQL (versão >= 13 recomendada).
2. Execute o arquivo SQL para criar o schema e popular dados de exemplo:
   ```bash
   psql -U seu_usuario -d seu_banco -f schema_oficina_full.sql
   ```

---

## Perguntas que as consultas respondem
- Quantas ordens de serviço cada cliente teve?
- Quais ordens de serviço estão aguardando peças?
- Qual é o custo total (serviços + peças) por ordem de serviço?
- Quais peças têm estoque baixo?
- Qual funcionário realizou mais horas de trabalho no período?

---

## Consultas de Exemplo (SELECT, WHERE, derived attrs, ORDER BY, HAVING, JOINs)

-- 1) Quantas OS cada cliente teve
```sql
SELECT a.account_id, a.display_name, COUNT(os.os_id) AS total_os
FROM accounts a
LEFT JOIN service_orders os ON os.account_id = a.account_id
GROUP BY a.account_id, a.display_name
ORDER BY total_os DESC;
```

-- 2) OS aguardando peças (filtro WHERE)
```sql
SELECT os_id, account_id, vehicle_id, opened_at, status
FROM service_orders
WHERE status = 'awaiting_parts'
ORDER BY opened_at ASC;
```

-- 3) Custo total da OS (atributo derivado: soma serviços + peças)
```sql
SELECT so.os_id,
       COALESCE(SUM(os_s.hours_worked * os_s.unit_price),0)
       + COALESCE((SELECT SUM(op.quantity * op.unit_cost) FROM os_parts op WHERE op.os_id = so.os_id),0) AS total_os
FROM service_orders so
LEFT JOIN os_services os_s ON os_s.os_id = so.os_id
GROUP BY so.os_id
ORDER BY total_os DESC;
```

-- 4) Peças com estoque baixo (ORDER BY)
```sql
SELECT p.part_id, p.name, ps.total_qty
FROM part_stock ps
JOIN parts p ON p.part_id = ps.part_id
WHERE ps.total_qty < 10
ORDER BY ps.total_qty ASC;
```

-- 5) Funcionários com mais horas trabalhadas (HAVING)
```sql
SELECT e.employee_id, e.full_name, SUM(os.hours_worked) AS total_hours
FROM employees e
JOIN os_services os ON os.performed_by = e.employee_id
GROUP BY e.employee_id, e.full_name
HAVING SUM(os.hours_worked) > 1
ORDER BY total_hours DESC;
```

---

## Estrutura do Repositório
```
.
├── README.md
└── schema_oficina_full.sql
```

