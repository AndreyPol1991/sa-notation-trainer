-- ==========================================================================
--  ФИТНЕС-ЦЕНТР · ВЕРСИЯ ДЛЯ ИМПОРТА В DrawDB (drawdb.app)
--
--  Отличия от fitness.sql — намеренно упрощено под парсер импорта:
--    • нет CREATE TYPE ... AS ENUM  → перечисления как VARCHAR + комментарий
--    • нет COMMENT ON              → пояснения обычными SQL-комментариями
--    • нет отдельных CREATE INDEX  → уникальность задана прямо в таблице
--    • TIMESTAMP вместо TIMESTAMPTZ, TEXT вместо JSONB
--
--  Как импортировать:
--    1. Открыть drawdb.app
--    2. File → Import from source (или Import diagram → From SQL)
--    3. Выбрать диалект PostgreSQL
--    4. Вставить весь текст этого файла и нажать Import
-- ==========================================================================

-- ---------- ЛЮДИ -----------------------------------------------------------

-- Сильная сущность. Физически не удаляется: на неё ссылаются брони и платежи
CREATE TABLE clients (
    id          BIGSERIAL    PRIMARY KEY,
    full_name   VARCHAR(255) NOT NULL,
    email       VARCHAR(255) NOT NULL UNIQUE,
    phone       VARCHAR(32),              -- varchar, не int: иначе съест ведущий ноль и плюс
    birth_date  DATE,
    referred_by BIGINT REFERENCES clients(id),   -- ссылка на самого себя: кто привёл клиента
                                          -- если импорт ругнётся на эту строку,
                                          -- уберите «REFERENCES clients(id)» и добавьте связь мышью
    created_at  TIMESTAMP    NOT NULL DEFAULT now(),
    deleted_at  TIMESTAMP                 -- мягкое удаление: NULL = клиент активен
);

-- Связь 1:1. Ключ здесь, потому что карта зависит от клиента, а не наоборот
CREATE TABLE client_cards (
    id            BIGSERIAL     PRIMARY KEY,
    client_id     BIGINT        NOT NULL UNIQUE REFERENCES clients(id),
    number        VARCHAR(32)   NOT NULL UNIQUE,
    bonus_balance DECIMAL(12,2) NOT NULL DEFAULT 0,   -- деньги только decimal, не float
    issued_at     TIMESTAMP     NOT NULL DEFAULT now()
);

-- Справочник. Удаление запрещено: на тренера ссылается всё расписание
CREATE TABLE trainers (
    id        BIGSERIAL    PRIMARY KEY,
    full_name VARCHAR(255) NOT NULL,
    hired_at  DATE         NOT NULL,
    is_active BOOLEAN      NOT NULL DEFAULT true
);

-- Справочник специализаций: йога, силовые, плавание
CREATE TABLE specialities (
    id    BIGSERIAL    PRIMARY KEY,
    code  VARCHAR(32)  NOT NULL UNIQUE,
    title VARCHAR(128) NOT NULL
);

-- Связующая таблица N:M со своим атрибутом
CREATE TABLE trainer_specialities (
    trainer_id    BIGINT NOT NULL REFERENCES trainers(id),
    speciality_id BIGINT NOT NULL REFERENCES specialities(id),
    certified_at  DATE,                   -- атрибут самой связи: сертификат выдан на ПАРУ
    PRIMARY KEY (trainer_id, speciality_id)
);

-- ---------- РАСПИСАНИЕ -----------------------------------------------------

CREATE TABLE halls (
    id       BIGSERIAL    PRIMARY KEY,
    title    VARCHAR(128) NOT NULL,
    capacity INT          NOT NULL        -- физическая вместимость зала
);

-- Свободные места НЕ хранятся: считаются как capacity минус активные брони
CREATE TABLE sessions (
    id           BIGSERIAL PRIMARY KEY,
    trainer_id   BIGINT    NOT NULL REFERENCES trainers(id),
    hall_id      BIGINT    NOT NULL REFERENCES halls(id),
    starts_at    TIMESTAMP NOT NULL,      -- timestamp, не строка: иначе не отсортировать
    duration_min INT       NOT NULL DEFAULT 60,
    capacity     INT       NOT NULL,      -- может быть меньше вместимости зала
    is_cancelled BOOLEAN   NOT NULL DEFAULT false,
    UNIQUE (hall_id, starts_at)           -- два занятия в одном зале одновременно нельзя
);

-- ---------- БРОНИ И ИСТОРИЯ ------------------------------------------------

-- Связующая сущность N:M между клиентом и занятием, со своими атрибутами
CREATE TABLE bookings (
    id         BIGSERIAL   PRIMARY KEY,
    client_id  BIGINT      NOT NULL REFERENCES clients(id),
    session_id BIGINT      NOT NULL REFERENCES sessions(id),
    status     VARCHAR(16) NOT NULL DEFAULT 'NEW',
                           -- NEW, CONFIRMED, CANCELLED, NO_SHOW, COMPLETED
    created_at TIMESTAMP   NOT NULL DEFAULT now(),
    UNIQUE (client_id, session_id)        -- вторая бронь на то же занятие запрещена
);

-- Аудит: кто, когда, из какого статуса в какой и почему
CREATE TABLE booking_status_history (
    id          BIGSERIAL    PRIMARY KEY,
    booking_id  BIGINT       NOT NULL REFERENCES bookings(id),
    from_status VARCHAR(16),              -- NULL при создании брони
    to_status   VARCHAR(16)  NOT NULL,
    changed_at  TIMESTAMP    NOT NULL DEFAULT now(),
    changed_by  BIGINT       REFERENCES clients(id),   -- NULL = изменила система
    actor       VARCHAR(16)  NOT NULL,    -- CLIENT, ADMIN, SYSTEM
    reason      VARCHAR(512)
);

-- ---------- АБОНЕМЕНТЫ И ДЕНЬГИ --------------------------------------------

CREATE TABLE membership_types (
    id            BIGSERIAL    PRIMARY KEY,
    code          VARCHAR(32)  NOT NULL UNIQUE,
    title         VARCHAR(128) NOT NULL,
    visits_total  INT,                    -- NULL = безлимит, ноль означал бы ноль посещений
    duration_days INT          NOT NULL
);

-- История цен: прайс меняется, прошлые значения сохраняются
CREATE TABLE membership_prices (
    id                 BIGSERIAL     PRIMARY KEY,
    membership_type_id BIGINT        NOT NULL REFERENCES membership_types(id),
    amount             DECIMAL(12,2) NOT NULL,
    valid_from         DATE          NOT NULL,
    valid_to           DATE,                -- NULL = цена действует сейчас
    UNIQUE (membership_type_id, valid_from)
);

CREATE TABLE memberships (
    id                 BIGSERIAL     PRIMARY KEY,
    client_id          BIGINT        NOT NULL REFERENCES clients(id),
    membership_type_id BIGINT        NOT NULL REFERENCES membership_types(id),
    price_paid         DECIMAL(12,2) NOT NULL,   -- цена зафиксирована в момент покупки
    visits_left        INT,
    state              VARCHAR(16)   NOT NULL DEFAULT 'ACTIVE',
                                     -- ACTIVE, FROZEN, EXPIRED
    starts_on          DATE          NOT NULL,
    ends_on            DATE          NOT NULL
);

CREATE TABLE payments (
    id            BIGSERIAL     PRIMARY KEY,
    client_id     BIGINT        NOT NULL REFERENCES clients(id),
    membership_id BIGINT        REFERENCES memberships(id),  -- NULL: платёж не только за абонемент
    amount        DECIMAL(12,2) NOT NULL,
    currency      CHAR(3)       NOT NULL DEFAULT 'RUB',
    status        VARCHAR(16)   NOT NULL DEFAULT 'PENDING',
                                -- PENDING, PAID, FAILED, REFUNDED
    external_id   VARCHAR(128)  UNIQUE,   -- идентификатор в шлюзе, защита от двойной обработки
    created_at    TIMESTAMP     NOT NULL DEFAULT now(),
    paid_at       TIMESTAMP
);

-- ---------- УВЕДОМЛЕНИЯ ----------------------------------------------------

-- Очередь: сайт создаёт письма быстрее, чем шлюз их отправляет
CREATE TABLE notifications (
    id         BIGSERIAL   PRIMARY KEY,
    client_id  BIGINT      NOT NULL REFERENCES clients(id),
    channel    VARCHAR(16) NOT NULL,      -- EMAIL, SMS, PUSH
    template   VARCHAR(64) NOT NULL,
    payload    TEXT        NOT NULL,      -- в PostgreSQL это будет jsonb
    created_at TIMESTAMP   NOT NULL DEFAULT now(),
    sent_at    TIMESTAMP,                 -- NULL = ещё в очереди
    attempts   INT         NOT NULL DEFAULT 0
);
