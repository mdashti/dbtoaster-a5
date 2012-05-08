-- How many employees who are joined in March 1985.

CREATE STREAM EMPLOYEE(
    employee_id     INT, 
    last_name       VARCHAR(30),
    first_name      VARCHAR(20),
    middle_name     CHAR(1),
    job_id          INT,
    manager_id      INT,
    hire_date       DATE,
    salary          FLOAT,
    commission      FLOAT,
    department_id   INT
    ) 
  FROM FILE '../../experiments/data/employee/employee.dat' LINE DELIMITED
  csv (fields := ',', schema := 'int,string,string,string,int,int,date,float,float,int', eventtype := 'insert');

SELECT year(hire_date), month(hire_date), count(*) AS no_of_employees
FROM employee 
WHERE year(hire_date)=1985 and month(hire_date)=3 
GROUP BY year(hire_date), month(hire_date)