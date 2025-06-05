#!/bin/bash

# Версія скрипта
VERSION="1.0"

# Змінні для аргументів
INPUT_FILE=""
GROUP=""
QUIET=false

# Обробка аргументів командного рядка
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            echo "Використання: $0 [--help | --version] | [[-q|--quiet] [академ_група] файл_із_cist.csv]"
            echo "  --help        Відображення довідки"
            echo "  --version     Відображення версії скрипта"
            echo "  -q, --quiet   Не виводити дані у stdout"
            exit 0
            ;;
        --version)
            echo "Версія: $VERSION"
            exit 0
            ;;
        -q|--quiet)
            QUIET=true
            ;;
        *.csv)
            INPUT_FILE="$1"
            ;;
        *)
            GROUP="$1"
            ;;
    esac
    shift
done

# Перевірка наявності файлу, якщо не вказано
if [ -z "$INPUT_FILE" ]; then
    # Знаходимо файли за шаблоном TimeTable_ДД_ММ_РРРР.csv
    files=($(ls | grep -E '^TimeTable_.._.._20..\.csv' | sort -t'_' -k2,2n -k3,3n -k4,4n))
    
    if [ ${#files[@]} -eq 0 ]; then
        echo "Помилка: файли TimeTable_ДД_ММ_РРРР.csv не знайдено" >&2
        exit 1
    fi

    files+=("Вийти")
    echo "Оберіть файл із розкладом:"
    select chosen_file in "${files[@]}"; do
        if [ "$chosen_file" = "Вийти" ]; then
            echo "Вихід із програми."
            exit 0
        fi
        if [ -n "$chosen_file" ]; then
            INPUT_FILE="$chosen_file"
            break
        else
            echo "Помилка: виберіть номер зі списку." >&2
        fi
    done
fi

# Перевірка існування файлу
if [ ! -f "$INPUT_FILE" ] || [ ! -r "$INPUT_FILE" ]; then
    echo "Помилка: файл $INPUT_FILE не існує або недоступний для читання" >&2
    exit 2
fi

# Витягуємо унікальні групи з файлу
groups=($(cat "$INPUT_FILE" | sed 's/\r/\n/g' | iconv -f CP1251 -t UTF-8 | awk '
    BEGIN { FPAT="[^,]*|\"[^\"]*\"" }
    NR > 1 {
        gsub(/^"|"$/, "", $1)
        if ($1 ~ /ПЗПІ-23-[0-9]+/) {
            match($1, /ПЗПІ-23-[0-9]+/)
            print substr($1, RSTART, RLENGTH)
        }
    }' | sort | uniq))

if [ ${#groups[@]} -eq 0 ]; then
    echo "Помилка: у файлі $INPUT_FILE не знайдено груп ПЗПІ-23-?" >&2
    exit 3
fi

# Якщо група не вказана, але є лише одна група
if [ -z "$GROUP" ] && [ ${#groups[@]} -eq 1 ]; then
    GROUP="${groups[0]}"
    echo "Знайдено лише одну групу: $GROUP"
elif [ -z "$GROUP" ]; then
    # Вибір групи через select
    echo "Доступні групи:"
    groups+=("Повернутись")
    select chosen_group in "${groups[@]}"; do
        if [ "$chosen_group" = "Повернутись" ]; then
            echo "Повернення до вибору файлу."
            exit 0
        fi
        if [ -n "$chosen_group" ]; then
            GROUP="$chosen_group"
            break
        else
            echo "Помилка: виберіть номер зі списку." >&2
        fi
    done
fi

# Перевірка, чи група є у файлі
if ! echo "${groups[@]}" | grep -qw "$GROUP"; then
    echo "Помилка: група $GROUP не знайдена у файлі $INPUT_FILE" >&2
    exit 4
fi

# Формуємо вихідний файл
output_file=$(echo "$INPUT_FILE" | sed 's/TimeTable/Google_TimeTable/')
echo "Формування розкладу для Google Календаря: $output_file"

# Створюємо тимчасові файли
tmp_data=$(mktemp)
sorted_data=$(mktemp)

# Гарантуємо видалення тимчасових файлів при виході
trap 'rm -f "$tmp_data" "$sorted_data"' EXIT

# Обробка CSV та фільтрація за групою
cat "$INPUT_FILE" | sed 's/\r/\n/g' | iconv -f CP1251 -t UTF-8 | awk -v GROUP="$GROUP" '
BEGIN {
    FS=","; OFS="\t"
}
NR == 1 { next }

function trim_quotes(s) {
    gsub(/^"|"$/, "", s)
    return s
}

{
    line = $0
    match(line, /"[0-3][0-9]\.[0-1][0-9]\.[0-9]{4}"/)
    if (RSTART == 0) { next }

    field1 = substr(line, 1, RSTART - 2)
    rest = substr(line, RSTART)

    n = 0; in_quotes = 0; field = ""
    for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (c == "\"") in_quotes = !in_quotes
        else if (c == "," && !in_quotes) {
            fields[++n] = field
            field = ""
        } else {
            field = field c
        }
    }
    fields[++n] = field
    for (i = 1; i <= n; i++) fields[i] = trim_quotes(fields[i])
    if (n < 6) next

    if ($1 !~ GROUP) next

    subject = trim_quotes(field1)
    sub(GROUP " - ", "", subject)

    desc = fields[11]
    type = "Інше"
    if (desc ~ /Лб/) type = "Лб"
    else if (desc ~ /Лк/) type = "Лк"
    else if (desc ~ /Пз/) type = "Пз"
    else if (desc ~ /Екз/) type = "Екз"

    sort_key = sprintf("%s%02d%02d%02d%02d", substr(fields[1],7,4), substr(fields[1],4,2), substr(fields[1],1,2), substr(fields[2],1,2), substr(fields[2],4,2))

    print subject, type, fields[1], fields[2], fields[3], fields[4], desc, sort_key
}' > "$tmp_data"




# Сортування за датою та часом
sort -t $'\t' -k8,8 "$tmp_data" > "$sorted_data"

# Форматування у CSV для Google Календаря
awk -F'\t' '
BEGIN {
    OFS = ","
    print "Subject,Start Date,Start Time,End Date,End Time,Description"
}

function format_date(date) {
    split(date, dmy, ".")
    return sprintf("%02d/%02d/%04d", dmy[2], dmy[1], dmy[3])
}

function format_time(time) {
    split(time, hmin, ":")
    h = hmin[1] + 0
    min = hmin[2]
    ap = (h >= 12) ? "PM" : "AM"
    if (h == 0) h = 12
    else if (h > 12) h -= 12
    return sprintf("%02d:%s %s", h, min, ap)
}

{
    subj_key = $1 "_" $2
    date_key = $3 "_" $7

    if ($2 == "Лб") {
        if (!(date_key in lab_seen)) {
            count[subj_key]++
            lab_seen[date_key] = count[subj_key]
        }
        number = lab_seen[date_key]
    } else {
        count[subj_key]++
        number = count[subj_key]
    }

    subject_full = $1 "; №" number
    start_date = format_date($3)
    start_time = format_time($4)
    end_date = format_date($5)
    end_time = format_time($6)
    desc = $7

    printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n", \
        subject_full, start_date, start_time, end_date, end_time, desc
}' "$sorted_data" | tee "$output_file"

# Вивід результату, якщо не -q
if [ "$QUIET" = false ]; then
    cat "$output_file"
fi

echo "Google-файл сформовано: $output_file"


