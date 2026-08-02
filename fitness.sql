-- ==========================================================================
--  ФИТНЕС-ЦЕНТР · СХЕМА ДАННЫХ (PostgreSQL)
--  Та же модель, что в fitness.dbml, но в виде DDL.
--  Нужна для импорта в инструменты, которые не понимают DBML:
--  DrawDB, Azimutt, DBeaver, pgModeler, Liam ERD, Moon Modeler.
--
--  Применить:  psql -d mydb -f fitness.sql
--  Или просто вставить текст в импорт схемы выбранного редактора.
-- ==========================================================================

-- ---------- перечисления ---------------------------------------------------
CREATE TYPE booking_status   AS ENUM ('NEW','CONFIRMED','CANCELLED','NO_SHOW','COMPLETED');
CREATE TYPE payment_status   AS ENUM ('PENDING','PAID','FAILED','REFUNDED');
CREATE TYPE membership_state AS ENUM ('ACTIVE','FROZEN','EXPIRED');
CREATE TYPE actor_type       AS ENUM ('CLIENT','ADMIN','SYSTEM');

-- ---------- люди -----------------------------------------------------------
CREATE TABLE clients (
    id          BIGSERIAL    PRIMARY KEY,
    full_name   VARCHAR(255) NOT NULL,
    email       VARCHAR(255) NOT NULL UNIQUE,
    phone       VARCHAR(32),
    birth_date  DATE,
    referred_by BIGINT       REFERENCES clients(id) ON DELETE SET NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at  TIMESTAMPTZ
);
COMMENT ON TABLE  clients             IS 'Сильная сущность. Физически не удаляется: на неё ссылаются брони и платежи';
COMMENT ON COLUMN clients.phone       IS 'varchar, а не int: иначе съест ведущий ноль и плюс';
COMMENT ON COLUMN clients.referred_by IS 'Ссылка на самого себя: кто привёл этого клиента';
COMMENT ON COLUMN clients.deleted_at  IS 'Мягкое удаление. NULL = клиент активен';

CREATE INDEX ix_clients_phone ON clients(phone);
CREATE INDEX ix_clients_created ON clients(created_at);

CREATE TABLE client_cards (
    id            BIGSERIAL     PRIMARY KEY,
    client_id     BIGINT        NOT NULL UNIQUE REFERENCES clients(id) ON DELETE CASCADE,
    number        VARCHAR(32)   NOT NULL UNIQUE,
    bonus_balance DECIMAL(12,2) NOT NULL DEFAULT 0,
    issued_at     TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  client_cards               IS 'Связь один к одному. Ключ здесь, потому что карта зависит от клиента';
COMMENT ON COLUMN client_cards.client_id     IS 'UNIQUE превращает связь в 1:1';
COMMENT ON COLUMN client_cards.bonus_balance IS 'Деньги только decimal, не float';

CREATE TABLE trainers (
    id        BIGSERIAL    PRIMARY KEY,
    full_name VARCHAR(255) NOT NULL,
    hired_at  DATE         NOT NULL,
    is_active BOOLEAN      NOT NULL DEFAULT true
);
COMMENT ON TABLE trainers IS 'Справочник. Удаление запрещено: на тренера ссылается всё расписание';

CREATE TABLE specialities (
    id    BIGSERIAL    PRIMARY KEY,
    code  VARCHAR(32)  NOT NULL UNIQUE,
    title VARCHAR(128) NOT NULL
);
COMMENT ON TABLE specialities IS 'Справочник специализаций: йога, силовые, плавание';

CREATE TABLE trainer_specialities (
    trainer_id    BIGINT NOT NULL REFERENCES trainers(id)     ON DELETE CASCADE,
    speciality_id BIGINT NOT NULL REFERENCES specialities(id) ON DELETE RESTRICT,
    certified_at  DATE,
    PRIMARY KEY (trainer_id, speciality_id)
);
COMMENT ON TABLE  trainer_specialities              IS 'Связующая таблица N:M со своим атрибутом';
COMMENT ON COLUMN trainer_specialities.certified_at IS 'Атрибут самой связи: сертификат выдан на ПАРУ';

-- ---------- расписание -----------------------------------------------------
CREATE TABLE halls (
    id       BIGSERIAL    PRIMARY KEY,
    title    VARCHAR(128) NOT NULL,
    capacity INT          NOT NULL
);
COMMENT ON COLUMN halls.capacity IS 'Физическая вместимость зала';

CREATE TABLE sessions (
    id           BIGSERIAL   PRIMARY KEY,
    trainer_id   BIGINT      NOT NULL REFERENCES trainers(id) ON DELETE RESTRICT,
    hall_id      BIGINT      NOT NULL REFERENCES halls(id)    ON DELETE RESTRICT,
    starts_at    TIMESTAMPTZ NOT NULL,
    duration_min INT         NOT NULL DEFAULT 60,
    capacity     INT         NOT NULL,
    is_cancelled BOOLEAN     NOT NULL DEFAULT false
);
COMMENT ON TABLE  sessions          IS 'Свободные места НЕ хранятся, а считаются: capacity минус активные брони';
COMMENT ON COLUMN sessions.starts_at IS 'timestamp, не строка: иначе не отсортировать';
COMMENT ON COLUMN sessions.capacity  IS 'Может быть меньше вместимости зала';

CREATE INDEX        ix_sessions_starts       ON sessions(starts_at);
CREATE INDEX        ix_sessions_trainer_time ON sessions(trainer_id, starts_at);
CREATE UNIQUE INDEX ux_hall_no_overlap       ON sessions(hall_id, starts_at);

-- ---------- брони и история -------------------------------------------------
CREATE TABLE bookings (
    id         BIGSERIAL      PRIMARY KEY,
    client_id  BIGINT         NOT NULL REFERENCES clients(id)  ON DELETE RESTRICT,
    session_id BIGINT         NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
    status     booking_status NOT NULL DEFAULT 'NEW',
    created_at TIMESTAMPTZ    NOT NULL DEFAULT now()
);
COMMENT ON TABLE bookings IS 'Связующая сущность N:M между клиентом и занятием, со своими атрибутами';

CREATE UNIQUE INDEX ux_one_booking_per_session ON bookings(client_id, session_id);
CREATE INDEX        ix_bookings_session_status ON bookings(session_id, status);

CREATE TABLE booking_status_history (
    id          BIGSERIAL      PRIMARY KEY,
    booking_id  BIGINT         NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
    from_status booking_status,
    to_status   booking_status NOT NULL,
    changed_at  TIMESTAMPTZ    NOT NULL DEFAULT now(),
    changed_by  BIGINT         REFERENCES clients(id) ON DELETE SET NULL,
    actor       actor_type     NOT NULL,
    reason      VARCHAR(512)
);
COMMENT ON TABLE  booking_status_history             IS 'Аудит: кто, когда, из какого статуса в какой и почему';
COMMENT ON COLUMN booking_status_history.from_status IS 'NULL при создании брони';
COMMENT ON COLUMN booking_status_history.changed_by  IS 'NULL = изменила система по таймауту';

CREATE INDEX ix_bsh_booking_time ON booking_status_history(booking_id, changed_at);

-- ---------- абонементы и деньги ---------------------------------------------
CREATE TABLE membership_types (
    id            BIGSERIAL    PRIMARY KEY,
    code          VARCHAR(32)  NOT NULL UNIQUE,
    title         VARCHAR(128) NOT NULL,
    visits_total  INT,
    duration_days INT          NOT NULL
);
COMMENT ON COLUMN membership_types.visits_total IS 'NULL означает безлимит. Ноль означал бы ноль посещений';

CREATE TABLE membership_prices (
    id                 BIGSERIAL     PRIMARY KEY,
    membership_type_id BIGINT        NOT NULL REFERENCES membership_types(id) ON DELETE RESTRICT,
    amount             DECIMAL(12,2) NOT NULL,
    valid_from         DATE          NOT NULL,
    valid_to           DATE
);
COMMENT ON TABLE  membership_prices          IS 'История цен. Прайс меняется, прошлые значения сохраняются';
COMMENT ON COLUMN membership_prices.valid_to IS 'NULL = цена действует сейчас';

CREATE UNIQUE INDEX ux_price_period ON membership_prices(membership_type_id, valid_from);

CREATE TABLE memberships (
    id                 BIGSERIAL        PRIMARY KEY,
    client_id          BIGINT           NOT NULL REFERENCES clients(id)          ON DELETE RESTRICT,
    membership_type_id BIGINT           NOT NULL REFERENCES membership_types(id) ON DELETE RESTRICT,
    price_paid         DECIMAL(12,2)    NOT NULL,
    visits_left        INT,
    state              membership_state NOT NULL DEFAULT 'ACTIVE',
    starts_on          DATE             NOT NULL,
    ends_on            DATE             NOT NULL
);
COMMENT ON COLUMN memberships.price_paid IS 'Осознанное дублирование: фиксирует условия сделки на момент покупки';

CREATE INDEX ix_memberships_client ON memberships(client_id, state);
CREATE INDEX ix_memberships_ends   ON memberships(ends_on);

CREATE TABLE payments (
    id            BIGSERIAL      PRIMARY KEY,
    client_id     BIGINT         NOT NULL REFERENCES clients(id)     ON DELETE RESTRICT,
    membership_id BIGINT         REFERENCES memberships(id)          ON DELETE SET NULL,
    amount        DECIMAL(12,2)  NOT NULL,
    currency      CHAR(3)        NOT NULL DEFAULT 'RUB',
    status        payment_status NOT NULL DEFAULT 'PENDING',
    external_id   VARCHAR(128)   UNIQUE,
    created_at    TIMESTAMPTZ    NOT NULL DEFAULT now(),
    paid_at       TIMESTAMPTZ
);
COMMENT ON COLUMN payments.membership_id IS 'NULL: платёж бывает не только за абонемент';
COMMENT ON COLUMN payments.external_id   IS 'Идентификатор в шлюзе, защищает от двойной обработки';

CREATE INDEX ix_payments_client ON payments(client_id, created_at);
CREATE INDEX ix_payments_status ON payments(status);

-- ---------- уведомления -----------------------------------------------------
CREATE TABLE notifications (
    id         BIGSERIAL   PRIMARY KEY,
    client_id  BIGINT      NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
    channel    VARCHAR(16) NOT NULL,
    template   VARCHAR(64) NOT NULL,
    payload    JSONB       NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at    TIMESTAMPTZ,
    attempts   INT         NOT NULL DEFAULT 0
);
COMMENT ON TABLE  notifications         IS 'Очередь. Сайт создаёт письма быстрее, чем шлюз их отправляет';
COMMENT ON COLUMN notifications.channel IS 'EMAIL, SMS или PUSH';
COMMENT ON COLUMN notifications.sent_at IS 'NULL = ещё в очереди';

CREATE INDEX ix_notifications_pending ON notifications(sent_at);
