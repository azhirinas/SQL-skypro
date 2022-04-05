/* 1. Узнаем, когда была первая транзакция для каждого студента.
Начиная с этой даты, будем собирать его баланс уроков. */

with first_payments
as (
    select user_id
        , min(transaction_datetime)::date as first_payment_date
    from skyeng_db.payments
    where status_name = 'success'
        and operation_name = 'Покупка уроков'
    group by user_id
  )

/* 2. Соберем таблицу с датами за каждый календарный день 2016 года. */

, all_dates 
as (
    select (generate_series('2016-01-01', '2016-12-31', '1 day'::interval))::date as dt
  )

/* 3. Узнаем, за какие даты имеет смысл собирать баланс для каждого студента. */ 

, all_dates_by_user
as (
select user_id
    , dt
from first_payments fp
    inner join all_dates ad
        on ad.dt >= fp.first_payment_date
  )
  
/* 4. Найдем изменения балансов студентов, связанные с успешными транзакциями. */

, payments_by_dates
as (
    select user_id
        , transaction_datetime::date as payment_date
        , sum(classes) as transaction_balance_change
    from skyeng_db.payments
    where status_name = 'success'
        and date_part('year', transaction_datetime) = 2016
    group by user_id
        , payment_date
   )
    
/* 5. Найдем баланс студентов, который сформирован только транзакциями. */

, payments_by_dates_cumsum
as (
    select adu.user_id
        , dt
        , transaction_balance_change
        , sum(coalesce(transaction_balance_change, 0)) over (partition by adu.user_id order by dt) as transaction_balance_change_cs
    from all_dates_by_user adu
        left join payments_by_dates pd
            on adu.user_id = pd.user_id
                and adu.dt = pd.payment_date
   )

/* 6. Найдем изменения балансов студентов, связанные с прохождением уроков. */

, classes_by_dates
as (
    select user_id
        , class_start_datetime::date as class_date
        , -1 * count(*) as classes_balance_change
    from skyeng_db.classes
    where class_status in ('success', 'failed_by_student')
        and class_type != 'trial'
        and date_part('year', class_start_datetime) = 2016
    group by user_id
        , class_date
   )
   
/* 7. Найдем баланс студентов, который сформирован только прохождением уроков. */

, classes_by_dates_dates_cumsum
as (
    select adu.user_id
            , dt
            , classes_balance_change
            , sum(coalesce(classes_balance_change, 0)) over (partition by adu.user_id order by dt) as classes_balance_change_cs
        from all_dates_by_user adu
            left join classes_by_dates cd
                on adu.user_id = cd.user_id
                    and adu.dt = cd.class_date
  )

/* 8. Найдем общий баланс студентов, сформированный транзакциями и прохождением уроков. */

, balances
as (
    select pdc.dt
    	, transaction_balance_change
    	, transaction_balance_change_cs
        , classes_balance_change
        , classes_balance_change_cs
        , transaction_balance_change_cs + classes_balance_change_cs as balance
    from payments_by_dates_cumsum pdc
        inner join classes_by_dates_dates_cumsum cdc
            on pdc.user_id = cdc.user_id
                and pdc.dt = cdc.dt
    -- where transaction_balance_change is not null
    -- or classes_balance_change is not null
    )

/* Задание 1. Выберите топ-1000 строк из CTE `balances` с сортировкой по `user_id` и `dt`.
Посмотрите на изменения балансов студентов. Какие вопросы стоит задать дата-инженерам и владельцам таблиц? */

-- select *
-- from balances 
-- order by user_id
--     , dt
-- limit 1000

-- Студенты с успешными не пробными уроками, у которых нет успешных оплат, и их уроки

, users_wo_successful_paymnets
as (
    select distinct user_id
    from skyeng_db.classes
    where user_id not in (
                          select distinct user_id from skyeng_db.payments 
                          where date_part('year', transaction_datetime) = 2016 and status_name = 'success'
                         )
        and date_part('year', class_start_datetime) = 2016 and class_status in ('success', 'failed_by_student')
        and class_type != 'trial'
   )

, classes_wo_successful_paymnets
as (
    select *
    from skyeng_db.classes
    where user_id in (select * from users_wo_successful_paymnets)
        and date_part('year', class_start_datetime) = 2016
        and class_status in ('success', 'failed_by_student')
        and class_type != 'trial')

/* 9. Посмотрим, как менялось общее количество уроков на балансе всех студентов. */

, final
as (
    select dt
        , sum(transaction_balance_change) as total_transaction_balance_change
        , sum(transaction_balance_change_cs) as total_transaction_balance_change_cs
        , sum(classes_balance_change) as total_classes_balance_change
        , sum(classes_balance_change_cs) as total_classes_balance_change_cs
        , sum(balance) as total_balance
    from balances
    group by dt
    order by dt
   )

/* Задание 2.Создайте визуализацию (линейную диаграмму) итогового результата. 
Какие выводы можно сделать из получившейся визуализации? */

-- Сезонность уроков

, sum_classes_by_dates
as (
    select class_date
        , sum(classes_balance_change) as day_classes_balance_change
    from classes_by_dates
    group by class_date
   )

, week_day_classes
as (
    select extract(dow from class_date) as week_day
        , min(day_classes_balance_change) as max_classes
        , avg(day_classes_balance_change) as avg_classes
        , max(day_classes_balance_change) as min_classes
    from sum_classes_by_dates
    group by week_day
    order by week_day
   )

, week_classes
as (
    select date_part('week', class_date) as week
        , min(day_classes_balance_change) as max_classes
        , avg(day_classes_balance_change) as avg_classes
        , max(day_classes_balance_change) as min_classes
    from sum_classes_by_dates
    group by week
    order by week
   )

, month_classes
as (
    select date_part('month', class_date) as mnth
        , min(day_classes_balance_change) as max_classes
        , avg(day_classes_balance_change) as avg_classes
        , max(day_classes_balance_change) as min_classes
    from sum_classes_by_dates
    group by mnth
    order by mnth
   )
   
-- Сезонность оплат

, sum_payments_by_dates   
as (
    select payment_date
        , sum(transaction_balance_change) as day_transaction_balance_change
    from payments_by_dates
    group by payment_date
   )   

, week_day_payments
as (
    select extract(dow from payment_date) as week_day
        , max(day_transaction_balance_change) as max_payments
        , avg(day_transaction_balance_change) as avg_payments
        , min(day_transaction_balance_change) as min_payments
    from sum_payments_by_dates 
    group by week_day
    order by week_day
   )

, week_payments
as (
    select date_part('week', payment_date) as week
        , max(day_transaction_balance_change) as max_payments
        , avg(day_transaction_balance_change) as avg_payments
        , min(day_transaction_balance_change) as min_payments
    from sum_payments_by_dates
    group by week
    order by week
   )

, month_payments
as (
    select date_part('month', payment_date) as mnth
        , max(day_transaction_balance_change) as max_payments
        , avg(day_transaction_balance_change) as avg_payments
        , min(day_transaction_balance_change) as min_payments
    from sum_payments_by_dates
    group by mnth
    order by mnth
   )
   
select *
from final
